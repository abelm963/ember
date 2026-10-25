import SwiftUI
import EmberKit

/// 2 · Sign in. Quick Connect first (approve a code on your phone, no typing on the TV),
/// or pick a user and type the password.
struct SignInView: View {
    @EnvironmentObject var app: AppModel
    @State private var users: [PublicUser] = []
    @State private var quickConnect = false
    @State private var code: String?
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?
    private enum Field: Hashable { case user(String), username, password, signIn }

    private var client: JellyfinClient { app.guestClient(app.serverURL ?? "") }

    var body: some View {
        HStack(alignment: .top, spacing: 110) {
            VStack(alignment: .leading, spacing: 24) {
                Text(app.serverName?.uppercased() ?? "JELLYFIN").eyebrow()
                Text("Sign in").font(.display(96)).displayTracking(96).foregroundStyle(C.text)
                if quickConnect {
                    quickConnectPanel
                } else {
                    Text("Quick Connect isn't switched on for this server. Sign in with your username and password, or ask the server admin to turn on Quick Connect in Jellyfin's Dashboard.")
                        .font(.body(26)).foregroundStyle(C.muted).lineSpacing(6).frame(maxWidth: 720, alignment: .leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 20) {
                    if !app.serverAccounts.isEmpty {
                        EmberButton(title: "Back to profiles", icon: "chevron.left", kind: .ghost, compact: true) {
                            app.phase = .profiles
                        }
                    }
                    EmberButton(title: "Change server", icon: "server.rack", kind: .ghost, compact: true) {
                        app.forgetServer()
                    }
                }
            }
            .frame(width: 760, alignment: .leading)

            VStack(alignment: .leading, spacing: 26) {
                if !users.isEmpty {
                    Text("WHO'S SIGNING IN?").eyebrow()
                    HStack(spacing: 30) {
                        ForEach(users.prefix(5)) { u in
                            Button {
                                username = u.name
                                focus = u.hasPassword ? .password : .signIn
                            } label: {
                                VStack(spacing: 14) {
                                    Avatar(name: u.name, image: u.imageTag.map { client.userImage(userId: u.id, tag: $0) }, size: 130)
                                    Text(u.name).font(.body(22, weight: .semibold)).foregroundStyle(C.text).lineLimit(1)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(LiftStyle(radius: 29, scale: 1.08))
                            .focused($focus, equals: .user(u.id))
                        }
                    }
                    .focusSection()
                }
                Text("USERNAME").eyebrow().padding(.top, 10)
                TextField("Username", text: $username)
                    .textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.body(30)).focused($focus, equals: .username)
                    .frame(width: 760)
                Text("PASSWORD").eyebrow()
                SecureField("Password", text: $password)
                    .textContentType(.password).font(.body(30)).focused($focus, equals: .password)
                    .onSubmit { Task { await signIn() } }
                    .frame(width: 760)
                EmberButton(title: busy ? "Signing in…" : "Sign In", icon: "arrow.right", kind: .primary) {
                    Task { await signIn() }
                }
                .focused($focus, equals: .signIn)
                .disabled(busy || username.isEmpty)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.body(24)).foregroundStyle(C.bad)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 120)
        .padding(.vertical, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await start() }
    }

    private var quickConnectPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("On your phone or computer, open Jellyfin › your profile › **Quick Connect** and enter this code:")
                .font(.body(26)).foregroundStyle(C.muted).lineSpacing(6).frame(maxWidth: 720, alignment: .leading)
            Text(code ?? "······")
                .font(.display(120)).tracking(18).foregroundStyle(C.accent)
                .padding(.vertical, 8)
            Text("Ember signs in by itself as soon as the code is approved.")
                .font(.body(22)).foregroundStyle(C.faint)
        }
    }

    private func start() async {
        users = (try? await client.publicUsers()) ?? []
        quickConnect = await client.quickConnectEnabled()
        guard quickConnect else { return }
        // Keep a fresh code on screen and wait for it to be approved.
        while !Task.isCancelled && app.phase == .signIn {
            let qc = client
            guard let started = try? await qc.quickConnectInitiate() else { return }
            let secret = started.secret
            code = started.code
            for _ in 0..<150 {  // A code lasts a few minutes; poll every 2 s.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                if (try? await qc.quickConnectAuthorized(secret: secret)) == true {
                    if let auth = try? await qc.authenticateWithQuickConnect(secret: secret) {
                        app.addAccount(auth, client: qc)
                    }
                    return
                }
            }
        }
    }

    private func signIn() async {
        busy = true
        error = nil
        defer { busy = false }
        let c = client
        do {
            let auth = try await c.authenticate(username: username, password: password)
            app.addAccount(auth, client: c)
            // Sign in to Seerr with the same details in the background, like the Flutter app.
            if app.seerr != nil, !app.seerrConfigured {
                _ = await app.seerrSignIn(username: username, password: password)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
