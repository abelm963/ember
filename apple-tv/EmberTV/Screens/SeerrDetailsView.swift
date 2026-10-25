import SwiftUI
import EmberKit

/// 14 · Preview before requesting / 15 · Request a title (Seerr).
struct SeerrDetailsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router
    let mediaType: String
    let tmdbId: Int

    @State private var media: SeerrMedia?
    @State private var inLibrary: JFItem?
    @State private var similar: [SeerrMedia] = []
    @State private var error: String?
    @State private var choosingSeasons = false
    @State private var requesting = false
    @State private var requested = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let m = media {
                RemoteImage(url: m.largeBackdropURL ?? m.backdropURL, alignment: .top) { C.bg }
                    .frame(width: 1920, height: 1080).overlay(Scrim()).ignoresSafeArea()
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 50) {
                        header(m).frame(minHeight: 900, alignment: .bottomLeading)
                        if !similar.isEmpty {
                            MediaRow(title: "More Like This", leading: Metrics.gutter + 40) {
                                ForEach(similar) { s in
                                    MediaTile(title: s.title, image: s.backdropURL,
                                              badge: s.isAvailable ? "On your server" : s.isRequested ? "Requested" : nil,
                                              badgeAlt: s.isRequested) { router.open(s) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 120)
                }
                .scrollClipDisabled()
            } else if let error {
                MessageView(title: "Couldn't load this title", message: error)
            } else {
                LoadingView()
            }
        }
        .background(C.bg)
        .ignoresSafeArea()
        .task { await load() }
        .sheet(isPresented: $choosingSeasons) {
            if let m = media { SeasonPicker(media: m) { seasons in Task { await request(seasons: seasons) } } }
        }
    }

    private func header(_ m: SeerrMedia) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            Text(statusLine(m)).eyebrow()
            TitleArt(name: m.title, logo: nil, maxWidth: 900, fontSize: 100)
            HStack(spacing: 18) {
                if let v = m.voteAverage, v > 0 {
                    Text("★ \(v, specifier: "%.1f")").font(.body(25, weight: .bold)).foregroundStyle(C.good)
                }
                if let y = m.year { Text(String(y)).font(.body(25)).foregroundStyle(C.muted) }
                if let c = m.certification { Badge(text: c) }
                if let r = m.runtime, r > 0 { Text(Labels.runtime(seconds: Double(r * 60))).font(.body(25)).foregroundStyle(C.muted) }
                if let n = m.numberOfSeasons { Text("\(n) Season\(n == 1 ? "" : "s")").font(.body(25)).foregroundStyle(C.muted) }
                if !m.genres.isEmpty { Text(m.genres.prefix(2).joined(separator: " · ")).font(.body(25)).foregroundStyle(C.muted) }
            }
            if let o = m.overview {
                Text(o).font(.body(26)).foregroundStyle(C.soft).lineSpacing(6).lineLimit(5).frame(maxWidth: 980, alignment: .leading)
            }
            let cast = m.cast.prefix(4).compactMap { $0["name"].string }
            if !cast.isEmpty {
                (Text("Starring  ").foregroundStyle(C.faint) + Text(cast.joined(separator: ", ")).foregroundStyle(C.muted))
                    .font(.body(22)).lineLimit(1)
            }
            HStack(spacing: 18) {
                if let inLibrary {
                    EmberButton(title: "Play", icon: "play.fill", kind: .primary) { router.play(inLibrary) }
                    EmberButton(title: "More Info", icon: "info.circle") { router.open(inLibrary) }
                } else if m.isRequested || requested {
                    Label("Requested", systemImage: "checkmark.circle.fill")
                        .font(.body(27, weight: .bold)).foregroundStyle(C.good)
                        .padding(.horizontal, 30).frame(height: 72)
                        .background(C.surface3, in: RoundedRectangle(cornerRadius: Metrics.buttonRadius))
                } else if app.seerrConfigured {
                    EmberButton(title: requesting ? "Requesting…" : "Request", icon: "arrow.down.circle", kind: .accent) {
                        if m.isTv { choosingSeasons = true } else { Task { await request(seasons: nil) } }
                    }
                    .disabled(requesting)
                }
                if let key = m.bestTrailerKey {
                    EmberButton(title: "Trailer", icon: "film") { router.playTrailer(youtube: key, title: m.title) }
                }
            }
            .padding(.top, 14)
            .focusSection()
        }
        .padding(.leading, Metrics.gutter + 40)
        .padding(.trailing, 600)
        .padding(.top, 80)
    }

    private func statusLine(_ m: SeerrMedia) -> String {
        if inLibrary != nil { return "ON YOUR SERVER" }
        if m.isRequested || requested { return "REQUESTED · COMING TO YOUR LIBRARY" }
        switch m.status {
        case .partiallyAvailable: return "PARTLY ON YOUR SERVER"
        default: return m.isTv ? "SERIES · NOT ON YOUR SERVER" : "FILM · NOT ON YOUR SERVER"
        }
    }

    private func load() async {
        guard let seerr = app.seerr else {
            error = "Seerr isn't set up. Add it in Settings › Requests."
            return
        }
        do {
            let m = try await seerr.details(mediaType, tmdbId: tmdbId)
            media = m
            if m.status == .available || m.status == .partiallyAvailable {
                inLibrary = try? await app.jf?.find(tmdbId: String(tmdbId), mediaType: mediaType, title: m.title)
            }
            similar = (try? await seerr.similar(mediaType, tmdbId: tmdbId)) ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func request(seasons: [Int]?) async {
        guard let seerr = app.seerr, let m = media else { return }
        requesting = true
        defer { requesting = false }
        do {
            try await seerr.request(mediaType: m.mediaType, tmdbId: m.id, seasons: seasons)
            requested = true
            app.show("Requested \(m.title)")
        } catch {
            app.show(error.localizedDescription)
        }
    }
}

/// Choose which seasons of a series to request.
private struct SeasonPicker: View {
    let media: SeerrMedia
    let done: ([Int]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text("Request \(media.title)").font(.display(56)).foregroundStyle(C.text)
            Text("Choose the seasons you'd like. New seasons are added automatically when you pick “All seasons”.")
                .font(.body(25)).foregroundStyle(C.muted)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(media.seasons.compactMap { $0["seasonNumber"].int }, id: \.self) { n in
                        Button {
                            if picked.contains(n) { picked.remove(n) } else { picked.insert(n) }
                        } label: {
                            HStack {
                                Text("Season \(n)").font(.body(28, weight: .semibold))
                                Spacer()
                                Image(systemName: picked.contains(n) ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                            }
                            .padding(.horizontal, 30).frame(height: 76)
                        }
                        .buttonStyle(PanelStyle())
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 520)
            HStack(spacing: 20) {
                EmberButton(title: "All seasons", kind: .accent) {
                    done(nil)
                    dismiss()
                }
                EmberButton(title: "Request \(picked.count) season\(picked.count == 1 ? "" : "s")", kind: .primary) {
                    done(picked.sorted())
                    dismiss()
                }
                .disabled(picked.isEmpty)
            }
        }
        .padding(80)
        .frame(width: 1100)
    }
}
