import SwiftUI
import EmberKit

/// 17 · Settings & account.
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var seerrAddress = ""
    @State private var seerrBusy = false
    @State private var serverVersion: String?
    @State private var showSeerrPassword = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 50) {
                Text("Settings").font(.display(72)).displayTracking(72).foregroundStyle(C.text)

                group("Profile") {
                    row(icon: "person.crop.circle", title: app.account?.name ?? "", detail: "Switch profile") { app.switchProfile() }
                    row(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", detail: "Removes this profile from this Apple TV") {
                        Task { await app.signOut() }
                    }
                }

                group("Playback") {
                    row(icon: "dial.medium", title: "Streaming quality", detail: app.qualityOption.label) {
                        let all = QualityOption.all
                        let i = all.firstIndex { $0.id == app.quality } ?? 0
                        app.quality = all[(i + 1) % all.count].id
                    }
                    toggle(icon: "forward.end", title: "Skip intros automatically", isOn: $app.autoSkipIntro)
                    toggle(icon: "forward", title: "Play the next episode automatically", isOn: $app.autoplayNext)
                    toggle(icon: "play.rectangle", title: "Play muted previews on Home", isOn: $app.autoplayPreviews)
                    note("Dolby Vision, HDR and frame rate follow your Apple TV's Video and Audio › Match Content settings.")
                }

                group("Requests (Seerr)") {
                    if app.seerrURL == nil {
                        TextField("Seerr address, for example seerr.example.ts.net", text: $seerrAddress)
                            .textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .font(.body(28)).frame(width: 1100)
                            .onSubmit { connectSeerr() }
                        row(icon: "link", title: "Connect Seerr", detail: seerrBusy ? "Checking…" : "Uses your Jellyfin sign-in") {
                            connectSeerr()
                        }
                    } else {
                        row(icon: "server.rack", title: app.seerrURL ?? "", detail: seerrStatus) {}
                        if app.seerrConfigured {
                            row(icon: "arrow.uturn.left", title: "Sign out of Seerr", detail: nil) { app.seerrSignOut() }
                        } else {
                            row(icon: "bolt.horizontal", title: "Sign in with Quick Connect",
                                detail: seerrBusy ? "Signing in…" : "No password needed") {
                                Task {
                                    seerrBusy = true
                                    if await app.seerrQuickConnect() { app.show("Signed in to Seerr") }
                                    seerrBusy = false
                                }
                            }
                        }
                        row(icon: "trash", title: "Remove Seerr", detail: nil) { app.setSeerrURL(nil) }
                    }
                    if let e = app.seerrError { note(e, color: C.bad) }
                    toggle(icon: "flame", title: "Show trending titles on Home", isOn: $app.showTrendingRow)
                }

                group("Trailers") {
                    row(icon: "film.stack", title: "Ember Trailers on \(app.serverName ?? "your server")",
                        detail: app.trailerService?["status"].string ?? "Not installed") {
                        Task { app.trailerService = await app.jf?.trailerHealth() }
                    }
                    note("Install or update the trailer plugin from Ember on Windows (Settings › Trailers & calendar).")
                }

                group("Server") {
                    row(icon: "externaldrive.connected.to.line.below", title: app.serverName ?? "Jellyfin",
                        detail: [app.serverURL, serverVersion.map { "Jellyfin \($0)" }].compactMap { $0 }.joined(separator: " · ")) {}
                    row(icon: "arrow.left.arrow.right", title: "Change server", detail: nil) { app.forgetServer() }
                }

                Text("Ember for Apple TV · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.body(20)).foregroundStyle(C.faint)
            }
            .padding(.leading, Metrics.gutter)
            .padding(.trailing, 300)
            .padding(.vertical, 80)
        }
        .task {
            serverVersion = try? await app.jf?.publicInfo()["Version"].string
            await app.refreshSeerrUser()
        }
    }

    private var seerrStatus: String {
        if app.seerrConfigured {
            let name = app.seerrUser?["displayName"].string ?? app.seerrUser?["jellyfinUsername"].string
            return name.map { "Signed in as \($0)" } ?? "Signed in"
        }
        return "Not signed in"
    }

    private func connectSeerr() {
        let address = seerrAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        seerrBusy = true
        Task {
            defer { seerrBusy = false }
            let probe = SeerrClient(baseURL: address)
            guard await probe.ping() else {
                app.seerrError = "That address didn't answer like a Seerr server."
                return
            }
            app.setSeerrURL(address)
            if await app.seerrQuickConnect() { app.show("Seerr connected") }
        }
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased()).eyebrow()
            content()
        }
        .focusSection()
    }

    private func row(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRowLabel(icon: icon, title: title, detail: detail, trailing: nil)
        }
        .buttonStyle(PanelStyle())
    }

    private func toggle(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            SettingsRowLabel(icon: icon, title: title, detail: nil, trailing: isOn.wrappedValue ? "On" : "Off")
        }
        .buttonStyle(PanelStyle())
    }

    private func note(_ text: String, color: Color = C.faint) -> some View {
        Text(text).font(.body(21)).foregroundStyle(color).padding(.leading, 8)
    }
}

private struct SettingsRowLabel: View {
    let icon: String
    let title: String
    let detail: String?
    let trailing: String?
    @Environment(\.panelFocused) private var focused

    var body: some View {
        HStack(spacing: 26) {
            Image(systemName: icon).font(.system(size: 28, weight: .semibold)).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body(27, weight: .semibold)).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.body(21)).foregroundStyle(focused ? C.ink.opacity(0.7) : C.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 20)
            if let trailing {
                Text(trailing).font(.body(24, weight: .bold)).foregroundStyle(trailing == "On" ? (focused ? C.ink : C.accent) : C.faint)
            }
        }
        .padding(.horizontal, 30)
        .frame(minHeight: 84)
        .frame(width: 1300, alignment: .leading)
    }
}
