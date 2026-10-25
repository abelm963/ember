import SwiftUI
import EmberKit

enum AppSection: String, CaseIterable, Identifiable {
    case search, home, shows, movies, newHot, myList, requests, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .home: return "Home"
        case .shows: return "Shows"
        case .movies: return "Movies"
        case .newHot: return "New & Hot"
        case .myList: return "My List"
        case .requests: return "Requests"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .home: return "house"
        case .shows: return "tv"
        case .movies: return "film"
        case .newHot: return "flame"
        case .myList: return "plus"
        case .requests: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

/// The signed-in app: a collapsed menu on the left that opens when focus moves onto it,
/// and the current section beside it. Detail pages and the player cover the whole screen.
struct MainView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var router: Router
    @State private var section: AppSection = .home
    @FocusState private var menuFocus: MenuTarget?

    enum MenuTarget: Hashable { case profile, section(AppSection) }

    init(app: AppModel) {
        _router = StateObject(wrappedValue: Router(app: app))
    }

    private var menuOpen: Bool { menuFocus != nil }

    var body: some View {
        NavigationStack(path: $router.path) {
            ZStack(alignment: .leading) {
                page
                    .id(section)
                    .padding(.leading, Metrics.menuCollapsed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                    // Back from a page opens the menu; Back on the menu leaves the app.
                    .onExitCommand { menuFocus = .section(section) }

                LinearGradient(colors: [Color(hex: 0x050506, opacity: 0.96), Color(hex: 0x050506, opacity: 0.8),
                                        Color(hex: 0x050506, opacity: 0.4)],
                               startPoint: .leading, endPoint: .trailing)
                    .ignoresSafeArea()
                    .opacity(menuOpen ? 1 : 0)
                    .allowsHitTesting(false)

                sideMenu
            }
            .ignoresSafeArea()
            .background(C.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case .item(let item): DetailsView(itemId: item.id, preview: item)
                    case .itemId(let id): DetailsView(itemId: id, preview: nil)
                    case .seerr(let type, let id): SeerrDetailsView(mediaType: type, tmdbId: id)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        .environmentObject(router)
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .home: HomeView()
        case .search: SearchView()
        case .shows: LibraryView(kind: .shows)
        case .movies: LibraryView(kind: .movies)
        case .newHot: NewHotView()
        case .myList: MyListView()
        case .requests: RequestsView()
        case .settings: SettingsView()
        }
    }

    private var sideMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                app.switchProfile()
            } label: {
                HStack(spacing: 22) {
                    Avatar(name: app.account?.name ?? "?", image: app.account.flatMap(app.imageURL(for:)), size: 52)
                    if menuOpen {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.account?.name ?? "").font(.body(26, weight: .bold))
                            Text("Switch profile").font(.body(19)).opacity(0.7)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuItemStyle(selected: false))
            .focused($menuFocus, equals: .profile)
            .padding(.bottom, 30)

            ForEach(AppSection.allCases.filter { $0 != .settings }) { s in item(s) }
            Spacer()
            item(.settings)
        }
        .padding(.vertical, 60)
        .padding(.horizontal, 22)
        .frame(width: menuOpen ? Metrics.menuOpen : Metrics.menuCollapsed, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: [C.bg.opacity(menuOpen ? 0 : 0.85), C.bg.opacity(0)], startPoint: .leading, endPoint: .trailing)
        }
        .focusSection()
        .animation(.easeOut(duration: 0.2), value: menuOpen)
    }

    private func item(_ s: AppSection) -> some View {
        Button {
            section = s
            menuFocus = nil
        } label: {
            HStack(spacing: 26) {
                Image(systemName: s.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 36)
                if menuOpen {
                    Text(s.label).font(.body(28, weight: .bold)).lineLimit(1).transition(.opacity)
                }
            }
            .padding(.horizontal, 20).frame(height: 66)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuItemStyle(selected: s == section))
        .focused($menuFocus, equals: .section(s))
    }
}

/// Menu entries: the current section is orange; the focused one is a white pill.
private struct MenuItemStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { MenuItemBody(configuration: configuration, selected: selected) }

    struct MenuItemBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? C.ink : selected ? C.accent : C.muted)
                .background(focused ? C.text : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}
