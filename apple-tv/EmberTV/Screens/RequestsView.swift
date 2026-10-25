import SwiftUI
import EmberKit

/// 16 · My requests (Seerr): status and download progress; admins can approve or decline.
struct RequestsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: Router
    @State private var filter = "All"
    @State private var refresh = 0

    private let filters = ["All", "Pending", "Approved", "Available", "Declined"]

    var body: some View {
        if !app.seerrConfigured {
            MessageView(title: "Requests aren't set up",
                        message: app.seerrError ?? "Add your Seerr address in Settings to request movies and shows that aren't on the server.")
        } else {
            Loader(id: "\(refresh)-\(app.revision)", load: load) { rows in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 34) {
                        Text("Requests").font(.display(72)).displayTracking(72).foregroundStyle(C.text)
                        HStack(spacing: 14) {
                            ForEach(filters, id: \.self) { f in
                                Button(f) { filter = f }
                                    .buttonStyle(EmberButtonStyle(kind: f == filter ? .accent : .ghost, compact: true))
                            }
                        }
                        .focusSection()
                        let shown = rows.filter { filter == "All" || $0.request.filterKey == filter }
                        if shown.isEmpty {
                            Text(filter == "All" ? "No requests yet. Find something in Search or New & Hot and press Request."
                                                 : "Nothing \(filter.lowercased()).")
                                .font(.body(26)).foregroundStyle(C.muted).padding(.top, 30)
                        }
                        ForEach(shown, id: \.request.id) { row in requestRow(row) }
                    }
                    .padding(.leading, Metrics.gutter)
                    .padding(.trailing, 120)
                    .padding(.vertical, 80)
                }
            }
        }
    }

    struct Row {
        let request: SeerrRequest
        let media: SeerrMedia?
    }

    private func load() async throws -> [Row] {
        guard let seerr = app.seerr else { return [] }
        let list = try await seerr.requests(take: 60)
        // Titles and artwork come from TMDB through Seerr, fetched side by side.
        var details: [Int: SeerrMedia] = [:]
        await withTaskGroup(of: (Int, SeerrMedia?).self) { group in
            for r in list {
                guard let id = r.tmdbId else { continue }
                group.addTask { (r.id, try? await seerr.details(r.mediaType, tmdbId: id)) }
            }
            for await (id, m) in group { details[id] = m }
        }
        return list.map { Row(request: $0, media: details[$0.id]) }
    }

    private func requestRow(_ row: Row) -> some View {
        let r = row.request
        return HStack(alignment: .center, spacing: 30) {
            Button {
                if let id = r.jellyfinId {
                    router.path.append(Route.itemId(id))
                } else if let m = row.media {
                    router.open(m)
                }
            } label: {
                HStack(spacing: 30) {
                    RemoteImage(row.media?.posterURL)
                        .frame(width: 110, height: 165)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(row.media?.title ?? "Title \(r.tmdbId ?? 0)").font(.body(30, weight: .bold)).lineLimit(1)
                        Text(details(r, row.media)).font(.body(22)).opacity(0.75).lineLimit(1)
                        HStack(spacing: 14) {
                            Text(r.label).font(.body(22, weight: .bold)).foregroundStyle(color(r))
                            if let p = r.downloadProgress {
                                ProgressView(value: p).tint(C.accent).frame(width: 260)
                                Text("\(Int(p * 100))%").font(.body(22, weight: .semibold))
                                if let eta = r.downloadETA {
                                    Text("· done \(eta.formatted(.relative(presentation: .named)))").font(.body(22)).opacity(0.75)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .buttonStyle(PanelStyle())

            if app.canManageRequests && r.status == 1 {
                EmberButton(title: "Approve", icon: "checkmark", kind: .accent, compact: true) { Task { await act(r, approve: true) } }
                EmberButton(title: "Decline", icon: "xmark", kind: .ghost, compact: true) { Task { await act(r, approve: false) } }
            }
        }
        .focusSection()
    }

    private func details(_ r: SeerrRequest, _ m: SeerrMedia?) -> String {
        var parts = [r.mediaType == "tv" ? "Series" : "Film"]
        if let y = m?.year { parts.append(String(y)) }
        if !r.seasonNumbers.isEmpty { parts.append("Seasons " + r.seasonNumbers.map(String.init).joined(separator: ", ")) }
        parts.append("requested by \(r.requestedBy)")
        if let d = r.createdAt { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func color(_ r: SeerrRequest) -> Color {
        switch r.filterKey {
        case "Available": return C.good
        case "Declined": return C.bad
        case "Pending": return C.warn
        default: return C.blue
        }
    }

    private func act(_ r: SeerrRequest, approve: Bool) async {
        guard let seerr = app.seerr else { return }
        do {
            if approve { try await seerr.approve(r.id) } else { try await seerr.decline(r.id) }
            app.show(approve ? "Approved" : "Declined")
            refresh += 1
        } catch {
            app.show(error.localizedDescription)
        }
    }
}

/// New & Hot: what's coming to the library, and what everyone's watching.
struct NewHotView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Loader(id: app.revision, load: load) { rows in
            if rows.isEmpty {
                MessageView(title: "Nothing new right now",
                            message: app.seerrConfigured ? nil : "Set up Seerr in Settings to see what's trending and coming soon.")
            } else {
                BrowseScreen(hero: nil, heroEyebrow: nil, rows: rows)
            }
        }
    }

    private func load() async throws -> [HomeRow] {
        guard let jf = app.jf else { return [] }
        let seerr = app.seerrConfigured ? app.seerr : nil
        async let upcoming = (try? jf.upcomingEpisodes()) ?? []
        async let trending = (try? seerr?.trending()) ?? []
        async let movies = (try? seerr?.upcoming("movie")) ?? []
        async let shows = (try? seerr?.upcoming("tv")) ?? []
        var rows: [HomeRow] = []
        let u = await upcoming
        if !u.isEmpty { rows.append(HomeRow(id: "upcoming", title: "Coming soon to your library", entries: u.map(Entry.item))) }
        let t = await trending
        if !t.isEmpty { rows.append(HomeRow(id: "trending", title: "Everyone's watching", entries: t.map(Entry.seerr))) }
        let m = await movies
        if !m.isEmpty { rows.append(HomeRow(id: "movies", title: "Coming soon · Films", entries: m.map(Entry.seerr))) }
        let s = await shows
        if !s.isEmpty { rows.append(HomeRow(id: "shows", title: "Coming soon · Series", entries: s.map(Entry.seerr))) }
        return rows
    }
}
