import SwiftUI
import EmberKit

/// One tile on Home: a library item or a title from Seerr.
enum Entry: Identifiable, Hashable {
    case item(JFItem)
    case seerr(SeerrMedia)

    var id: String {
        switch self {
        case .item(let i): return "jf:\(i.id)"
        case .seerr(let m): return "seerr:\(m.key)"
        }
    }
}

/// A row of tiles on Home and the browse pages.
struct HomeRow: Identifiable {
    enum Kind { case resume, nextUp, browse }
    let id: String
    let title: String
    var kind: Kind = .browse
    let entries: [Entry]
}

/// 4 · Home.
struct HomeView: View {
    @EnvironmentObject var app: AppModel

    struct HomeData {
        var hero: JFItem?
        var rows: [HomeRow]
    }

    var body: some View {
        Loader(id: app.revision, load: load) { data in
            if data.hero == nil && data.rows.isEmpty {
                MessageView(title: "Your library is empty",
                            message: "Add some movies or shows to Jellyfin and they'll appear here.")
            } else {
                BrowseScreen(hero: data.hero, heroEyebrow: nil, rows: data.rows)
            }
        }
    }

    private func load() async throws -> HomeData {
        guard let jf = app.jf else { return HomeData(rows: []) }
        let views = try await jf.views()
        async let resume = (try? jf.resume()) ?? []
        async let nextUp = (try? jf.nextUp()) ?? []
        async let favorites = (try? jf.favorites()) ?? []
        let seerr = app.showTrendingRow && app.seerrConfigured ? app.seerr : nil
        async let trending = (try? seerr?.trending()) ?? []

        let libs = views.filter { $0.collectionType == "movies" || $0.collectionType == "tvshows" }
        var latest: [(JFItem, [JFItem])] = []
        await withTaskGroup(of: (Int, [JFItem]).self) { group in
            for (i, lib) in libs.enumerated() {
                group.addTask { (i, (try? await jf.latest(parentId: lib.id)) ?? []) }
            }
            var found: [Int: [JFItem]] = [:]
            for await (i, items) in group { found[i] = items }
            latest = libs.indices.compactMap { i in found[i].map { (libs[i], $0) } }
        }

        let r = await resume
        let n = await nextUp
        var rows: [HomeRow] = []
        if !r.isEmpty { rows.append(HomeRow(id: "resume", title: "Continue Watching", kind: .resume, entries: r.map(Entry.item))) }
        let freshNext = n.filter { e in !r.contains { $0.id == e.id } }
        if !freshNext.isEmpty { rows.append(HomeRow(id: "next", title: "Next Up", kind: .nextUp, entries: freshNext.map(Entry.item))) }
        let t = await trending.filter { !$0.isAvailable }
        if !t.isEmpty {
            rows.append(HomeRow(id: "trending", title: "Trending — not in your library yet", entries: t.map(Entry.seerr)))
        }
        for (lib, items) in latest where !items.isEmpty {
            rows.append(HomeRow(id: "latest-\(lib.id)", title: "Recently added in \(lib.name)", entries: items.map(Entry.item)))
        }
        let fav = await favorites
        if !fav.isEmpty { rows.append(HomeRow(id: "mylist", title: "My List", entries: fav.map(Entry.item))) }

        // Billboard: a recent movie or series with artwork, with full details for the badges.
        let pool = latest.flatMap(\.1).filter { ($0.isMovie || $0.isSeries) && !$0.backdropTags.isEmpty }
        var hero: JFItem?
        if let pick = pool.prefix(8).randomElement() {
            hero = (try? await jf.item(pick.id)) ?? pick
            if let h = hero { await ImageStore.shared.warm([jf.backdropImage(h), jf.logoImage(h)]) }
        }
        return HomeData(hero: hero, rows: rows)
    }
}

/// The browse layout shared by Home, Shows and Movies: a billboard that follows focus,
/// with rows of tiles underneath.
struct BrowseScreen: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router
    let hero: JFItem?
    /// Line above the title on the billboard; nil = "FILM · NEW IN YOUR LIBRARY".
    let heroEyebrow: String?
    let rows: [HomeRow]

    @State private var spotlight: Entry?
    @State private var heroMode = true
    @State private var spotlightTask: Task<Void, Never>?
    @FocusState private var heroFocus: HeroButton?
    private enum HeroButton: Hashable { case play, info }

    private var shown: Entry? { heroMode ? hero.map(Entry.item) : (spotlight ?? hero.map(Entry.item)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 0) {
                info
                    .frame(height: heroMode ? 650 : 470, alignment: .bottomLeading)
                    .padding(.leading, Metrics.gutter)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(rows) { row in
                                MediaRow(title: row.title) {
                                    ForEach(row.entries) { entry in
                                        tile(entry, row: row) {
                                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(row.id, anchor: .top) }
                                        }
                                    }
                                }
                                .id(row.id)
                            }
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 500)
                    }
                    .scrollClipDisabled()
                    // Back from the rows returns to the billboard first, like the big streaming apps.
                    .onExitCommand {
                        if hero != nil {
                            heroFocus = .play
                            if let first = rows.first { withAnimation { proxy.scrollTo(first.id, anchor: .top) } }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: heroMode)
        .onChange(of: heroFocus) { _, now in if now != nil { heroMode = true } }
        .onAppear { if hero != nil { heroFocus = .play } }
        .onDisappear { spotlightTask?.cancel() }
    }

    // MARK: Backdrop

    private var backdropURL: URL? {
        switch shown {
        case .item(let i): return app.jf?.backdropImage(i)
        case .seerr(let m): return m.largeBackdropURL ?? m.backdropURL
        case nil: return nil
        }
    }

    private var backdrop: some View {
        ZStack(alignment: .topTrailing) {
            C.bg
            RemoteImage(url: backdropURL, alignment: .top) { C.bg }
                .id(backdropURL)
                .transition(.opacity)
                .frame(width: 1920 * 0.78, height: 1080 * 0.78)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if heroMode, let hero, app.autoplayPreviews {
                HeroPreview(item: hero)
                    .frame(width: 1920 * 0.78, height: 1080 * 0.78)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Scrim()
                .frame(width: 1920 * 0.78, height: 1080 * 0.78)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .animation(.easeInOut(duration: 0.45), value: backdropURL)
        .frame(width: 1920 - Metrics.menuCollapsed, height: 1080, alignment: .topTrailing)
    }

    // MARK: Billboard / spotlight info

    @ViewBuilder private var info: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch shown {
            case .item(let item):
                Text(eyebrow(item)).eyebrow()
                TitleArt(name: item.isEpisode ? (item.seriesName ?? item.name) : item.name,
                         logo: app.jf?.logoImage(item), maxHeight: heroMode ? 180 : 130, fontSize: heroMode ? 100 : 76)
                if item.isEpisode {
                    Text("\(item.episodeLabel)  ·  \(item.name)").font(.body(25, weight: .semibold)).foregroundStyle(C.soft)
                }
                MetaLine(item: item)
                if let o = item.overview {
                    Text(o).font(.body(25)).foregroundStyle(C.soft).lineSpacing(5).lineLimit(heroMode ? 3 : 2)
                        .frame(maxWidth: 860, alignment: .leading)
                }
            case .seerr(let m):
                Text(m.isRequested ? "REQUESTED · COMING TO YOUR LIBRARY" : "TRENDING · NOT ON YOUR SERVER").eyebrow()
                TitleArt(name: m.title, logo: nil, maxHeight: 130, fontSize: 76)
                HStack(spacing: 18) {
                    if let v = m.voteAverage, v > 0 {
                        Text("★ \(v, specifier: "%.1f")").font(.body(23, weight: .bold)).foregroundStyle(C.good)
                    }
                    if let y = m.year { Text(String(y)).font(.body(23)).foregroundStyle(C.muted) }
                    Badge(text: m.isTv ? "Series" : "Film")
                }
                if let o = m.overview {
                    Text(o).font(.body(25)).foregroundStyle(C.soft).lineSpacing(5).lineLimit(2).frame(maxWidth: 860, alignment: .leading)
                }
            case nil:
                EmptyView()
            }
            if let hero {
                // Kept in place (invisible) while browsing rows, so Up from the first row lands here.
                HStack(spacing: 18) {
                    EmberButton(title: hero.progress != nil ? "Resume" : "Play", icon: "play.fill", kind: .primary) {
                        router.play(hero)
                    }
                    .focused($heroFocus, equals: .play)
                    EmberButton(title: "More Info", icon: "info.circle") { router.open(hero) }
                        .focused($heroFocus, equals: .info)
                }
                .padding(.top, 10)
                .opacity(heroMode ? 1 : 0)
                .focusSection()
            }
        }
        .padding(.bottom, heroMode ? 40 : 30)
        .id(shown?.id)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: shown?.id)
    }

    private func eyebrow(_ item: JFItem) -> String {
        if heroMode, item.id == hero?.id, let heroEyebrow { return heroEyebrow }
        if heroMode, item.id == hero?.id { return item.isSeries ? "SERIES · NEW IN YOUR LIBRARY" : "FILM · NEW IN YOUR LIBRARY" }
        if item.isEpisode || item.isSeries { return "SERIES" }
        return "FILM"
    }

    // MARK: Tiles

    @ViewBuilder
    private func tile(_ entry: Entry, row: HomeRow, focused: @escaping () -> Void) -> some View {
        let onFocus = {
            heroMode = false
            focused()
            spotlightTask?.cancel()
            // Wait a moment so fast swiping along a row doesn't flicker the artwork.
            spotlightTask = Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                if !Task.isCancelled { spotlight = entry }
            }
        }
        switch entry {
        case .item(let it):
            let play = row.kind == .resume || row.kind == .nextUp
            MediaTile(title: it.isEpisode ? (it.seriesName ?? it.name) : it.name,
                      subtitle: it.isEpisode ? it.episodeLabel : (row.kind == .resume ? Labels.timeLeft(it) : nil),
                      image: app.jf?.landscapeImage(it),
                      progress: row.kind == .resume ? it.progress : nil,
                      onFocus: onFocus) {
                if play { router.play(it) } else { router.open(it) }
            }
            .contextMenu {
                Button("More Info") { router.open(it) }
                Button(it.isFavorite ? "Remove from My List" : "Add to My List") { Task { _ = await app.toggleMyList(it) } }
            }
        case .seerr(let m):
            MediaTile(title: m.title, image: m.backdropURL, badge: m.isRequested ? "Requested" : "Not on server",
                      badgeAlt: m.isRequested, onFocus: onFocus) {
                router.open(m)
            }
        }
    }
}
