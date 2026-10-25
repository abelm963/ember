import SwiftUI
import EmberKit

/// 8 · Search: a letter grid on the left (fast with the remote), results on the right.
/// Finds titles in your library and, through Seerr, ones you can request.
struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router
    @State private var query = ""
    @State private var library: [JFItem] = []
    @State private var requestable: [SeerrMedia] = []
    @State private var searching = false
    @State private var typing = false

    private let keys = Array("abcdefghijklmnopqrstuvwxyz1234567890").map(String.init)

    var body: some View {
        HStack(alignment: .top, spacing: 70) {
            keyboard.frame(width: 520)
            results
        }
        .padding(.leading, Metrics.gutter)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: query) { await search() }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .semibold)).foregroundStyle(C.muted)
                Text(query.isEmpty ? "Search" : query)
                    .font(.body(36, weight: .semibold))
                    .foregroundStyle(query.isEmpty ? C.faint : C.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24).frame(height: 76)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surface2, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 14) {
                key(label: "space", icon: "space", width: 166) { query += " " }
                key(label: "delete", icon: "delete.left", width: 166) { if !query.isEmpty { query.removeLast() } }
                key(label: "keyboard", icon: "keyboard", width: 166) { typing = true }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(74), spacing: 14), count: 6), spacing: 14) {
                ForEach(keys, id: \.self) { k in
                    key(label: k, icon: nil, width: 74) { query += k }
                }
            }
            if !query.isEmpty {
                EmberButton(title: "Clear", icon: "xmark", kind: .ghost, compact: true) { query = "" }
            }
        }
        .focusSection()
        .sheet(isPresented: $typing) {
            // The system keyboard, which also offers dictation from the Siri Remote.
            VStack(spacing: 30) {
                Text("Search").font(.display(60)).foregroundStyle(C.text)
                TextField("Title, person or genre", text: $query).font(.body(32)).frame(width: 900)
                    .onSubmit { typing = false }
                EmberButton(title: "Done", kind: .primary) { typing = false }
            }
            .padding(80)
        }
    }

    private func key(label: String, icon: String?, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 28, weight: .semibold)) }
                else { Text(label.uppercased()).font(.body(30, weight: .bold)) }
            }
            .frame(width: width, height: 74)
        }
        .buttonStyle(PanelStyle(radius: 12))
        .accessibilityLabel(label)
    }

    @ViewBuilder private var results: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type a title to search your library and everything you can request.")
                        .font(.body(28)).foregroundStyle(C.muted).padding(.top, 20)
                } else if searching && library.isEmpty && requestable.isEmpty {
                    LoadingView().frame(height: 400)
                } else if library.isEmpty && requestable.isEmpty {
                    Text("Nothing found for “\(query)”.").font(.body(28)).foregroundStyle(C.muted).padding(.top, 20)
                }
                if !library.isEmpty {
                    grid(title: "In your library") {
                        ForEach(library) { it in
                            MediaTile(title: it.name, subtitle: it.year.map(String.init), image: app.jf?.landscapeImage(it),
                                      width: 330) { router.open(it) }
                        }
                    }
                }
                if !requestable.isEmpty {
                    grid(title: "Not on your server yet") {
                        ForEach(requestable) { m in
                            MediaTile(title: m.title, subtitle: m.year.map(String.init), image: m.backdropURL,
                                      badge: m.isRequested ? "Requested" : "Request", badgeAlt: m.isRequested, width: 330) {
                                router.open(m)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 120)
            .padding(.trailing, 60)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func grid<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.body(30, weight: .bold)).foregroundStyle(C.text)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(330), spacing: 34, alignment: .top), count: 3),
                      alignment: .leading, spacing: 40) { content() }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            library = []
            requestable = []
            return
        }
        // Wait for a pause in typing.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, let jf = app.jf else { return }
        searching = true
        defer { searching = false }
        async let lib = (try? jf.search(q)) ?? []
        let seerr = app.seerrConfigured ? app.seerr : nil
        async let more = (try? seerr?.search(q)) ?? []
        let found = await lib
        let ids = Set(found.compactMap(\.tmdbId))
        let extra = await more.filter { !$0.isAvailable && !ids.contains(String($0.id)) }
        guard !Task.isCancelled else { return }
        library = found
        requestable = extra
    }
}
