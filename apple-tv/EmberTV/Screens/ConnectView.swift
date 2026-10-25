import SwiftUI
import EmberKit

/// 1 · Connect to server: type Hearth's address once; Ember remembers it.
struct ConnectView: View {
    @EnvironmentObject var app: AppModel
    @State private var address = Storage.string("lastAddress") ?? ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 26) {
                Text("ember").font(.display(84)).displayTracking(84).foregroundStyle(C.accent)
                Text("Connect to your\nJellyfin server").font(.display(76)).displayTracking(76).foregroundStyle(C.text)
                Text("Type the address you use for Jellyfin, for example **hearth:8096** at home or your Tailscale address. Ember remembers it.")
                    .font(.body(27)).foregroundStyle(C.muted).lineSpacing(6).frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: 820, alignment: .leading)

            VStack(alignment: .leading, spacing: 28) {
                Text("SERVER ADDRESS").eyebrow()
                TextField("hearth:8096", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.body(30))
                    .focused($fieldFocused)
                    .onSubmit { Task { await connect() } }
                    .frame(width: 760)
                EmberButton(title: checking ? "Connecting…" : "Connect", icon: "arrow.right", kind: .primary) {
                    Task { await connect() }
                }
                .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.body(24)).foregroundStyle(C.bad).frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .padding(120)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topTrailing) {
            RadialGradient(colors: [C.accent.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 1200)
                .ignoresSafeArea()
        }
        .onAppear { fieldFocused = address.isEmpty }
    }

    private func connect() async {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        checking = true
        error = nil
        defer { checking = false }
        let client = app.guestClient(url)
        do {
            let info = try await client.publicInfo()
            Storage.set(url, "lastAddress")
            app.setServer(url: client.baseURL, name: info["ServerName"].string ?? "Jellyfin")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
