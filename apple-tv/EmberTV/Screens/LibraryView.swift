import SwiftUI
import EmberKit

/// 6 · Shows / Movies: a billboard and one row per genre.
struct LibraryView: View {
    enum Kind {
        case shows, movies
        var types: [String] { self == .shows ? ["Series"] : ["Movie"] }
        var eyebrow: String { self == .shows ? "SERIES" : "FILMS" }
        var noun: String { self == .shows ? "shows" : "movies" }
    }

    @EnvironmentObject var app: AppModel
    let kind: Kind

    var body: some View {
        Loader(id: app.revision, load: load) { data in
            if data.rows.isEmpty {
                MessageView(title: "No \(kind.noun) yet", message: "Add \(kind.noun) to Jellyfin and they'll appear here.")
            } else {
                BrowseScreen(hero: data.hero, heroEyebrow: kind.eyebrow, rows: data.rows)
            }
        }
    }

    private func load() async throws -> HomeView.HomeData {
        guard let jf = app.jf else { return .init(rows: []) }
        let types = kind.types
        async let recent = (try? jf.items(types: types, sortBy: "DateCreated", sortOrder: "Descending", limit: 24)) ?? []
        async let unwatched = (try? jf.items(types: types, sortBy: "Random", filters: "IsUnplayed", limit: 24)) ?? []
        let genres = Array(((try? await jf.genres(types: types)) ?? []).prefix(14))

        var byGenre: [String: [JFItem]] = [:]
        await withTaskGroup(of: (String, [JFItem]).self) { group in
            for g in genres {
                group.addTask { (g, (try? await jf.items(types: types, genre: g, sortBy: "Random", limit: 24)) ?? []) }
            }
            for await (g, items) in group { byGenre[g] = items }
        }

        var rows: [HomeRow] = []
        let r = await recent
        if !r.isEmpty { rows.append(HomeRow(id: "recent", title: "New in your library", entries: r.map(Entry.item))) }
        let u = await unwatched
        if !u.isEmpty { rows.append(HomeRow(id: "unwatched", title: "You haven't watched yet", entries: u.map(Entry.item))) }
        for g in genres {
            if let items = byGenre[g], items.count >= 3 {
                rows.append(HomeRow(id: "genre-\(g)", title: g, entries: items.map(Entry.item)))
            }
        }

        var hero: JFItem?
        if let pick = (u + r).filter({ !$0.backdropTags.isEmpty }).prefix(10).randomElement() {
            hero = (try? await jf.item(pick.id)) ?? pick
        }
        return .init(hero: hero, rows: rows)
    }
}

/// 7 · My List: everything added with + (Jellyfin favourites).
struct MyListView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router

    var body: some View {
        Loader(id: app.revision, load: { try await app.jf?.favorites() ?? [] }) { items in
            if items.isEmpty {
                MessageView(title: "My List is empty",
                            message: "Press + on any title to save it here for later.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        Text("My List").font(.display(72)).displayTracking(72).foregroundStyle(C.text)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(Metrics.tileWidth), spacing: 40, alignment: .top), count: 4),
                                  alignment: .leading, spacing: 50) {
                            ForEach(items) { it in
                                MediaTile(title: it.name, subtitle: it.year.map(String.init), image: app.jf?.landscapeImage(it)) {
                                    router.open(it)
                                }
                            }
                        }
                    }
                    .padding(.leading, Metrics.gutter)
                    .padding(.vertical, 80)
                }
                .scrollClipDisabled()
            }
        }
    }
}
