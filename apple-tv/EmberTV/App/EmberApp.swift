import SwiftUI
import EmberKit

@main
struct EmberApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}

/// Picks the screen for where the person is: connecting, signing in, choosing a profile, or in.
struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()
            switch app.phase {
            case .connect: ConnectView()
            case .signIn: SignInView()
            case .profiles: ProfilesView()
            case .main: MainView(app: app).id(app.currentAccountId)
            }
            if let t = app.toast { ToastView(text: t).zIndex(10) }
        }
        .animation(.easeInOut(duration: 0.25), value: app.phase)
        .tint(C.accent)
    }
}

/// Where the person can go from any screen.
enum Route: Hashable {
    case item(JFItem)
    case itemId(String)
    case seerr(type: String, id: Int)
}

/// Opens pages and starts playback. Shared through the environment.
@MainActor
final class Router: ObservableObject {
    @Published var path = NavigationPath()
    unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    func open(_ item: JFItem) {
        // Episodes and seasons open their series, like the big streaming apps.
        if (item.isEpisode || item.isSeason), let sid = item.seriesId {
            path.append(Route.itemId(sid))
        } else {
            path.append(Route.item(item))
        }
    }

    func open(_ media: SeerrMedia) {
        path.append(Route.seerr(type: media.mediaType, id: media.id))
    }

    /// Plays an item, resuming unless `fromStart`. Series play their next episode.
    func play(_ item: JFItem, fromStart: Bool = false) {
        guard let jf = app.jf else { return }
        if item.isSeries {
            Task {
                do {
                    guard let ep = try await jf.episodeToPlay(series: item) else {
                        app.show("No episodes on the server yet.")
                        return
                    }
                    PlayerPresenter.shared.play(ep, app: app, fromStart: false)
                } catch {
                    app.show(error.localizedDescription)
                }
            }
            return
        }
        PlayerPresenter.shared.play(item, app: app, fromStart: fromStart)
    }

    /// Plays a trailer inside Ember when the server's trailer service can stream it,
    /// otherwise in the YouTube app.
    func playTrailer(item: JFItem? = nil, youtube: String? = nil, title: String) {
        guard let jf = app.jf else { return }
        Task {
            if let item {
                if let local = await jf.localTrailers(item.id).first {
                    PlayerPresenter.shared.play(local, app: app, fromStart: true, isTrailer: true)
                    return
                }
            }
            var key = youtube
            if key == nil, let item {
                key = item.remoteTrailers.lazy.compactMap { youtubeKey($0["Url"].string) }.first
            }
            if app.trailerServiceOK {
                var playable: String?
                if let item {
                    playable = await jf.trailerCheck(itemId: item.id).key
                } else if let key {
                    playable = await jf.trailerKeyChecked(key)
                }
                if let playable {
                    PlayerPresenter.shared.playURL(jf.trailerStreamURL(playable), title: "\(title) · Trailer")
                    return
                }
            }
            if let key, let url = URL(string: "youtube://watch/\(key)"), await UIApplication.shared.open(url) {
                return
            }
            app.show("No trailer available for this title.")
        }
    }
}
