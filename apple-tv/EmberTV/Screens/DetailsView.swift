import SwiftUI
import EmberKit

/// 9 · Movie details / 10 · Series & episodes.
struct DetailsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router
    let itemId: String
    /// What the tile already knew, shown while the full details load.
    let preview: JFItem?

    @State private var item: JFItem?
    @State private var seasons: [JFItem] = []
    @State private var season: JFItem?
    @State private var episodes: [JFItem] = []
    @State private var similar: [JFItem] = []
    @State private var error: String?
    @FocusState private var playFocused: Bool

    private var shown: JFItem? { item ?? preview }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let it = shown {
                RemoteImage(url: app.jf?.backdropImage(it), alignment: .top) { C.bg }
                    .frame(width: 1920, height: 1080)
                    .overlay(Scrim())
                    .ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 50) {
                        header(it).frame(minHeight: 900, alignment: .bottomLeading)
                        if it.isSeries { episodesSection }
                        if !it.people.isEmpty { castRow(it) }
                        if !similar.isEmpty {
                            MediaRow(title: "More Like This", leading: Metrics.gutter + 40) {
                                ForEach(similar) { s in
                                    MediaTile(title: s.name, image: app.jf?.landscapeImage(s)) { router.open(s) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 120)
                }
                .scrollClipDisabled()
            } else if let error {
                MessageView(title: "Couldn't open this title", message: error)
            } else {
                LoadingView()
            }
        }
        .background(C.bg)
        .ignoresSafeArea()
        .task(id: "\(itemId)-\(app.revision)") { await load() }
    }

    // MARK: Header

    private func header(_ it: JFItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            Text(it.isSeries ? "SERIES" : "FILM").eyebrow()
            TitleArt(name: it.name, logo: app.jf?.logoImage(it), maxWidth: 720, maxHeight: 200, fontSize: 104)
            MetaLine(item: it, size: 25)
            let formats = FormatInfo(streams: it.mediaStreams).badges.filter { !["4K", "HD"].contains($0) }
            if !formats.isEmpty {
                HStack(spacing: 12) { ForEach(formats, id: \.self) { Badge(text: $0) } }
            }
            if let o = it.overview {
                Text(o).font(.body(26)).foregroundStyle(C.soft).lineSpacing(6).lineLimit(4)
                    .frame(maxWidth: 980, alignment: .leading)
            }
            credits(it)
            buttons(it).padding(.top, 14)
        }
        .padding(.leading, Metrics.gutter + 40)
        .padding(.trailing, 600)
        .padding(.top, 80)
        .focusSection()
    }

    @ViewBuilder private func credits(_ it: JFItem) -> some View {
        let actors = it.people.filter { $0["Type"].string == "Actor" }.prefix(4).compactMap { $0["Name"].string }
        let directors = it.people.filter { $0["Type"].string == "Director" }.prefix(2).compactMap { $0["Name"].string }
        VStack(alignment: .leading, spacing: 6) {
            if !actors.isEmpty {
                (Text("Starring  ").foregroundStyle(C.faint) + Text(actors.joined(separator: ", ")).foregroundStyle(C.muted))
                    .font(.body(22)).lineLimit(1)
            }
            if !directors.isEmpty {
                (Text("Director  ").foregroundStyle(C.faint) + Text(directors.joined(separator: ", ")).foregroundStyle(C.muted))
                    .font(.body(22)).lineLimit(1)
            }
        }
    }

    private func buttons(_ it: JFItem) -> some View {
        HStack(spacing: 18) {
            EmberButton(title: playLabel(it), icon: "play.fill", kind: .primary) { router.play(it) }
                .focused($playFocused)
            if it.progress != nil {
                EmberButton(title: "Restart", icon: "arrow.counterclockwise") { router.play(it, fromStart: true) }
            }
            if hasTrailer(it) {
                EmberButton(title: "Trailer", icon: "film") { router.playTrailer(item: it, title: it.name) }
            }
            EmberButton(title: "", icon: it.isFavorite ? "checkmark" : "plus") {
                Task {
                    if let now = await app.toggleMyList(it) { item = it.with(userData: "IsFavorite", .bool(now)) }
                }
            }
            .accessibilityLabel(it.isFavorite ? "Remove from My List" : "Add to My List")
            EmberButton(title: "", icon: it.played ? "eye.slash" : "eye") {
                Task {
                    guard let jf = app.jf else { return }
                    do {
                        try await jf.setPlayed(it.id, !it.played)
                        item = it.with(userData: "Played", .bool(!it.played))
                        app.show(it.played ? "Marked as unwatched" : "Marked as watched")
                        app.libraryChanged()
                    } catch {
                        app.show(error.localizedDescription)
                    }
                }
            }
            .accessibilityLabel(it.played ? "Mark as unwatched" : "Mark as watched")
        }
    }

    private func playLabel(_ it: JFItem) -> String {
        if it.isSeries { return "Play" }
        return it.progress != nil ? "Resume" : "Play"
    }

    private func hasTrailer(_ it: JFItem) -> Bool {
        it.localTrailerCount > 0 || !it.remoteTrailers.isEmpty
    }

    // MARK: Episodes

    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Episodes").font(.body(34, weight: .bold)).foregroundStyle(C.text).padding(.trailing, 20)
                ForEach(seasons) { s in
                    Button {
                        Task { await choose(s) }
                    } label: {
                        Text(s.name)
                    }
                    .buttonStyle(EmberButtonStyle(kind: s.id == season?.id ? .accent : .ghost, compact: true))
                }
            }
            .padding(.leading, Metrics.gutter + 40)
            .focusSection()

            MediaRow(title: "", leading: Metrics.gutter + 40) {
                ForEach(episodes) { e in
                    MediaTile(title: "\(e.indexNumber.map { "\($0). " } ?? "")\(e.name)",
                              subtitle: episodeSubtitle(e),
                              image: app.jf?.landscapeImage(e, maxWidth: 800),
                              progress: e.progress,
                              badge: e.played ? "Watched" : nil,
                              width: 460) {
                        router.play(e)
                    }
                }
            }
        }
    }

    private func episodeSubtitle(_ e: JFItem) -> String {
        [Labels.timeLeft(e) ?? Labels.runtime(seconds: e.runtime), e.overview ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func castRow(_ it: JFItem) -> some View {
        let people = it.people.filter { $0["Type"].string == "Actor" }.prefix(16)
        return VStack(alignment: .leading, spacing: 18) {
            Text("Cast").font(.body(30, weight: .bold)).foregroundStyle(C.text).padding(.leading, Metrics.gutter + 40)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 34) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, p in
                        Button {} label: {
                            VStack(spacing: 12) {
                                Avatar(name: p["Name"].string ?? "?", image: app.jf?.personImage(p), size: 150)
                                Text(p["Name"].string ?? "").font(.body(21, weight: .semibold)).foregroundStyle(C.text).lineLimit(1)
                                Text(p["Role"].string ?? "").font(.body(19)).foregroundStyle(C.faint).lineLimit(1)
                            }
                            .frame(width: 180)
                        }
                        .buttonStyle(LiftStyle(radius: 33, scale: 1.06))
                    }
                }
                .padding(.vertical, 20)
            }
            .safeAreaPadding(.horizontal, Metrics.gutter + 40)
            .scrollClipDisabled()
        }
        .focusSection()
    }

    // MARK: Loading

    private func load() async {
        guard let jf = app.jf else { return }
        do {
            let full = try await jf.item(itemId)
            item = full
            async let sim = (try? jf.similar(itemId)) ?? []
            if full.isSeries {
                seasons = (try? await jf.seasons(seriesId: full.id)) ?? []
                // Open on the season of the next episode to watch, like the big streaming apps.
                let next = try? await jf.episodeToPlay(series: full)
                let start = seasons.first { $0.id == next?.seasonId } ?? seasons.first
                if let start { await choose(start) }
            }
            similar = await sim
            if !playFocused { playFocused = true }
        } catch {
            if preview == nil { self.error = error.localizedDescription }
        }
    }

    private func choose(_ s: JFItem) async {
        guard let jf = app.jf, let series = shown else { return }
        season = s
        episodes = (try? await jf.episodes(seriesId: series.id, seasonId: s.id)) ?? []
    }
}
