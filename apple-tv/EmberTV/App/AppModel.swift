import Foundation
import SwiftUI
import UIKit
import EmberKit

/// Everything the app remembers and shares between screens: the server, the profiles
/// saved on this Apple TV, the Seerr connection and the person's settings.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case connect, signIn, profiles, main }

    @Published var phase: Phase = .connect
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var currentAccountId: String?

    @Published var serverURL: String?
    @Published var serverName: String?

    @Published var seerrURL: String?
    @Published var seerrUser: JSON?
    @Published var seerrError: String?
    /// Status from the server's Ember Trailers plugin; nil = not installed.
    @Published var trailerService: JSON?

    // Settings
    @Published var quality: String { didSet { Storage.set(quality, "quality") } }
    @Published var autoSkipIntro: Bool { didSet { Storage.set(autoSkipIntro, "autoSkipIntro") } }
    @Published var autoplayNext: Bool { didSet { Storage.set(autoplayNext, "autoplayNext") } }
    @Published var autoplayPreviews: Bool { didSet { Storage.set(autoplayPreviews, "autoplayPreviews") } }
    @Published var showTrendingRow: Bool { didSet { Storage.set(showTrendingRow, "showTrendingRow") } }

    /// Bumped when library data may have changed (played, added to My List…), so screens reload.
    @Published var revision = 0
    @Published var toast: String?

    private(set) var jf: JellyfinClient?
    private(set) var seerr: SeerrClient?
    let deviceId = Storage.deviceId
    let deviceName = UIDevice.current.name

    init() {
        quality = Storage.string("quality") ?? "original"
        autoSkipIntro = Storage.bool("autoSkipIntro", default: false)
        autoplayNext = Storage.bool("autoplayNext", default: true)
        autoplayPreviews = Storage.bool("autoplayPreviews", default: true)
        showTrendingRow = Storage.bool("showTrendingRow", default: true)
        serverURL = Storage.string("serverURL")
        serverName = Storage.string("serverName")
        seerrURL = Storage.string("seerrURL")
        currentAccountId = Storage.string("currentAccountId")
        accounts = Storage.loadAccounts()

        if serverURL == nil {
            phase = .connect
        } else if serverAccounts.isEmpty {
            phase = .signIn
        } else {
            // Like the big streaming apps: ask who's watching each time the app starts.
            phase = .profiles
        }
    }

    var account: Account? { accounts.first { $0.id == currentAccountId } }
    var serverAccounts: [Account] { accounts.filter { $0.serverURL == serverURL } }
    var seerrConfigured: Bool { seerr?.isSignedIn == true }
    var canManageRequests: Bool {
        if let u = seerrUser { return SeerrClient.canManageRequests(u) }
        return account?.isAdmin ?? false
    }
    var trailerServiceOK: Bool {
        let s = trailerService?["status"].string
        return s == "Online" || s == "Degraded"
    }
    var qualityOption: QualityOption { QualityOption.find(quality) }

    /// A Jellyfin client for a server that isn't signed in yet (address check, sign-in).
    func guestClient(_ url: String) -> JellyfinClient {
        JellyfinClient(baseURL: url, deviceId: deviceId, deviceName: deviceName)
    }

    // MARK: Server and profiles

    func setServer(url: String, name: String) {
        serverURL = JellyfinClient.normalize(url)
        serverName = name
        Storage.set(serverURL, "serverURL")
        Storage.set(name, "serverName")
        phase = serverAccounts.isEmpty ? .signIn : .profiles
    }

    func forgetServer() {
        serverURL = nil
        serverName = nil
        Storage.set(nil, "serverURL")
        Storage.set(nil, "serverName")
        phase = .connect
    }

    /// Saves a new sign-in as a profile and switches to it.
    func addAccount(_ auth: AuthResult, client: JellyfinClient) {
        guard let serverURL else { return }
        let acc = Account(serverURL: serverURL, serverName: serverName ?? "Jellyfin", userId: auth.userId,
                          name: auth.userName, token: auth.token, isAdmin: auth.isAdmin, imageTag: auth.primaryImageTag,
                          seerrCookie: accounts.first { $0.serverURL == serverURL && $0.userId == auth.userId }?.seerrCookie)
        accounts.removeAll { $0.id == acc.id }
        accounts.append(acc)
        Storage.saveAccounts(accounts)
        select(acc)
    }

    func select(_ acc: Account) {
        currentAccountId = acc.id
        Storage.set(acc.id, "currentAccountId")
        jf = JellyfinClient(baseURL: acc.serverURL, deviceId: deviceId, deviceName: deviceName,
                            token: acc.token, userId: acc.userId)
        rebuildSeerr()
        revision += 1
        phase = .main
        Task {
            await refreshSeerrUser()
            trailerService = await jf?.trailerHealth()
        }
    }

    func switchProfile() {
        phase = serverAccounts.isEmpty ? .signIn : .profiles
    }

    func signOut() async {
        guard let acc = account else { return }
        await remove(acc)
    }

    /// Signs a profile out on the server and forgets it on this Apple TV.
    func remove(_ acc: Account) async {
        await JellyfinClient(baseURL: acc.serverURL, deviceId: deviceId, deviceName: deviceName,
                             token: acc.token, userId: acc.userId).logout()
        accounts.removeAll { $0.id == acc.id }
        Storage.saveAccounts(accounts)
        if acc.id == currentAccountId {
            currentAccountId = nil
            jf = nil
            seerr = nil
            seerrUser = nil
            phase = serverAccounts.isEmpty ? .signIn : .profiles
        } else if serverAccounts.isEmpty {
            phase = .signIn
        }
    }

    func imageURL(for acc: Account) -> URL? {
        guard let tag = acc.imageTag else { return nil }
        return guestClient(acc.serverURL).userImage(userId: acc.userId, tag: tag)
    }

    // MARK: Seerr

    private func rebuildSeerr() {
        guard let url = seerrURL, !url.isEmpty else {
            seerr = nil
            return
        }
        let client = SeerrClient(baseURL: url, cookie: account?.seerrCookie)
        // When Seerr forgets the session, sign in again with Quick Connect (no password).
        client.reauth = { [weak self] in
            await self?.seerrQuickConnect(silent: true) ?? false
        }
        seerr = client
    }

    func setSeerrURL(_ url: String?) {
        seerrURL = url.map(SeerrClient.normalize)
        Storage.set(seerrURL, "seerrURL")
        seerrUser = nil
        seerrError = nil
        rebuildSeerr()
    }

    private func saveSeerrCookie() {
        guard let i = accounts.firstIndex(where: { $0.id == currentAccountId }) else { return }
        accounts[i].seerrCookie = seerr?.cookie
        Storage.saveAccounts(accounts)
    }

    func refreshSeerrUser() async {
        guard let seerr, seerr.isSignedIn else { return }
        do {
            seerrUser = try await seerr.me()
            seerrError = nil
        } catch {
            seerrError = error.localizedDescription
        }
    }

    /// Signs in to Seerr as the current Jellyfin user without typing a password: Seerr asks
    /// Jellyfin for a Quick Connect code and Ember approves it with the session it already has.
    @discardableResult
    func seerrQuickConnect(silent: Bool = false) async -> Bool {
        guard let seerr, let jf else { return false }
        do {
            try await seerr.signInWithQuickConnect { code in try await jf.authorizeQuickConnect(code: code) }
            saveSeerrCookie()
            seerrError = nil
            if !silent { await refreshSeerrUser() }
            return true
        } catch {
            seerrError = error.localizedDescription
            return false
        }
    }

    func seerrSignIn(username: String, password: String) async -> Bool {
        guard let seerr else { return false }
        do {
            try await seerr.signInWithJellyfin(username: username, password: password)
            saveSeerrCookie()
            await refreshSeerrUser()
            return true
        } catch {
            seerrError = error.localizedDescription
            return false
        }
    }

    func seerrSignOut() {
        seerr?.cookie = nil
        seerrUser = nil
        saveSeerrCookie()
    }

    // MARK: Small helpers for screens

    func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast == message { withAnimation { toast = nil } }
        }
    }

    func libraryChanged() { revision += 1 }

    /// Adds to / removes from My List (Jellyfin favourites) and says so.
    func toggleMyList(_ item: JFItem) async -> Bool? {
        guard let jf else { return nil }
        let add = !item.isFavorite
        do {
            try await jf.setFavorite(item.id, add)
            show(add ? "Added to My List" : "Removed from My List")
            libraryChanged()
            return add
        } catch {
            show(error.localizedDescription)
            return nil
        }
    }
}
