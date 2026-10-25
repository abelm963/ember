import SwiftUI
import EmberKit

// MARK: - Buttons

enum ButtonKind { case primary, secondary, accent, ghost }

/// Ember's pill buttons: white when focused, grown slightly, like the design.
struct EmberButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        EmberButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct EmberButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ButtonKind
    let compact: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        let (bg, fg) = colors
        configuration.label
            .font(.body(compact ? 24 : 27, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, compact ? 26 : 34)
            .frame(height: compact ? 60 : 72)
            .background(bg, in: RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous))
            .overlay {
                if focused && kind == .primary {
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous).stroke(C.accent, lineWidth: 3)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.05 : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 18, y: 8)
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var colors: (Color, Color) {
        switch kind {
        case .primary: return (C.text, C.ink)
        case .accent: return focused ? (C.text, C.ink) : (C.accent, C.accentInk)
        case .secondary: return focused ? (C.text, C.ink) : (Color(hex: 0x787880, opacity: 0.4), .white)
        case .ghost: return focused ? (C.text, C.ink) : (C.surface3, C.text)
        }
    }
}

/// A button with an SF Symbol and a label, in Ember's style.
struct EmberButton: View {
    let title: String
    var icon: String?
    var kind: ButtonKind = .secondary
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon { Image(systemName: icon).font(.system(size: compact ? 24 : 28, weight: .bold)) }
                if !title.isEmpty { Text(title) }
            }
        }
        .buttonStyle(EmberButtonStyle(kind: kind, compact: compact))
    }
}

/// Lifts the focused element and draws a white ring, used for artwork tiles and avatars.
struct LiftStyle: ButtonStyle {
    var radius: CGFloat = Metrics.tileRadius
    var scale: CGFloat = 1.1

    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration, radius: radius, scale: scale)
    }
}

private struct LiftBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    let scale: CGFloat
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white, lineWidth: focused ? 5 : 0)
            }
            .scaleEffect(configuration.isPressed ? scale - 0.03 : focused ? scale : 1)
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 24, y: 14)
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// Plain row-style button (settings rows, list rows): a panel that turns white when focused.
struct PanelStyle: ButtonStyle {
    var radius: CGFloat = 14
    func makeBody(configuration: Configuration) -> some View { PanelBody(configuration: configuration, radius: radius) }
}

private struct PanelBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label
            .foregroundStyle(focused ? C.ink : C.text)
            .background(focused ? C.text : C.surface2, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(focused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
            .environment(\.panelFocused, focused)
    }
}

private struct PanelFocusedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside a focused `PanelStyle` button, so secondary text can switch colour.
    var panelFocused: Bool {
        get { self[PanelFocusedKey.self] }
        set { self[PanelFocusedKey.self] = newValue }
    }
}

// MARK: - Tiles and rows

/// A 16:9 artwork tile with an optional progress bar and badge; the title shows underneath.
struct MediaTile: View {
    let title: String
    var subtitle: String?
    let image: URL?
    var progress: Double?
    var badge: String?
    var badgeAlt = false
    var width: CGFloat = Metrics.tileWidth
    /// Called when the remote moves onto this tile (Home uses it to update the billboard).
    var onFocus: (() -> Void)?
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: image) {
                        ZStack {
                            C.surface2
                            Text(title).font(.display(30)).foregroundStyle(C.muted)
                                .multilineTextAlignment(.center).padding(20)
                        }
                    }
                    if let progress {
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(C.accent).frame(width: width * progress)
                        }
                        .frame(height: 6)
                    }
                    if let badge {
                        Text(badge)
                            .font(.body(18, weight: .bold))
                            .foregroundStyle(badgeAlt ? C.accentInk : C.text)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(badgeAlt ? C.accent : .black.opacity(0.7), in: Capsule())
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous))
            }
            .buttonStyle(LiftStyle())
            .focused($isFocused)
            .onChange(of: isFocused) { _, now in if now { onFocus?() } }
            .accessibilityLabel(title)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body(24, weight: .semibold)).foregroundStyle(C.text).lineLimit(1)
                if let subtitle { Text(subtitle).font(.body(21)).foregroundStyle(C.muted).lineLimit(1) }
            }
            .frame(width: width, alignment: .leading)
        }
    }
}

/// A titled horizontal row. Rows snap so the focused tile sits on the left edge, as on
/// big streaming apps, and the row title lines up with the page gutter.
struct MediaRow<Content: View>: View {
    let title: String
    var leading: CGFloat = Metrics.gutter
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !title.isEmpty {
                Text(title)
                    .font(.body(30, weight: .bold))
                    .foregroundStyle(C.text)
                    .padding(.leading, leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) { content() }
                    .scrollTargetLayout()
                    .padding(.vertical, 26)
            }
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.leading, leading)
            .safeAreaPadding(.trailing, Metrics.gutter)
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Small pieces

/// Bordered label such as "PG-13" or "4K · HDR".
struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.body(20, weight: .bold))
            .foregroundStyle(C.soft)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(C.muted.opacity(0.7), lineWidth: 1.5))
    }
}

/// "★ 7.8  2024  PG-13  2h 46m  Sci-Fi · Adventure  4K · HDR"
struct MetaLine: View {
    let item: JFItem
    var size: CGFloat = 23

    var body: some View {
        HStack(spacing: 18) {
            if let r = item.communityRating {
                Text("★ \(r, specifier: "%.1f")").font(.body(size, weight: .bold)).foregroundStyle(C.good)
            }
            if let y = item.year { Text(String(y)).font(.body(size)).foregroundStyle(C.muted) }
            if let rating = item.officialRating { Badge(text: rating) }
            if item.isMovie, item.runtime != nil {
                Text(Labels.runtime(seconds: item.runtime)).font(.body(size)).foregroundStyle(C.muted)
            }
            if item.isSeries, let n = item.childCount {
                Text("\(n) Season\(n == 1 ? "" : "s")").font(.body(size)).foregroundStyle(C.muted)
            }
            if !item.genres.isEmpty {
                Text(item.genres.prefix(2).joined(separator: " · ")).font(.body(size)).foregroundStyle(C.muted)
            }
            if let v = FormatInfo(streams: item.mediaStreams).videoBadge { Badge(text: v) }
        }
        .lineLimit(1)
    }
}

/// A title's logo artwork, or its name in the display font when there is no logo.
struct TitleArt: View {
    let name: String
    let logo: URL?
    var maxWidth: CGFloat = 640
    var maxHeight: CGFloat = 180
    var fontSize: CGFloat = 96

    var body: some View {
        if let logo {
            RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading) { nameText }
                .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
                .frame(height: maxHeight, alignment: .bottomLeading)
        } else {
            nameText
        }
    }

    private var nameText: some View {
        Text(name)
            .font(.display(fontSize))
            .displayTracking(fontSize)
            .foregroundStyle(C.text)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: maxWidth + 300, alignment: .leading)
    }
}

/// A round avatar: the account's picture, or its initial on a warm colour.
struct Avatar: View {
    let name: String
    let image: URL?
    var size: CGFloat = 200

    var body: some View {
        RemoteImage(url: image) {
            ZStack {
                LinearGradient(colors: [Avatar.color(for: name), Avatar.color(for: name).opacity(0.65)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(name.prefix(1)).uppercased())
                    .font(.display(size * 0.45))
                    .foregroundStyle(C.accentInk)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    static func color(for name: String) -> Color {
        let palette: [Color] = [C.accent, C.warn, C.good, C.blue, C.bad, Color(hex: 0xC9A7F5)]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}

/// Loading, empty and error states.
struct LoadingView: View {
    var body: some View {
        ProgressView().progressViewStyle(.circular).tint(C.accent).scaleEffect(1.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageView: View {
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 22) {
            Text(title).font(.display(52)).foregroundStyle(C.text).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.body(26)).foregroundStyle(C.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            if let actionTitle, let action {
                EmberButton(title: actionTitle, kind: .primary, action: action).padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loads data once (and again when `id` changes), showing a spinner, then the content or an error.
struct Loader<Value, Content: View>: View {
    let id: AnyHashable
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content

    @State private var state: LoadState = .loading
    private enum LoadState { case loading, done(Value), failed(String) }

    init(id: AnyHashable = 0, load: @escaping () async throws -> Value, @ViewBuilder content: @escaping (Value) -> Content) {
        self.id = id
        self.load = load
        self.content = content
    }

    var body: some View {
        Group {
            switch state {
            case .loading: LoadingView()
            case .done(let v): content(v)
            case .failed(let msg):
                MessageView(title: "Something went wrong", message: msg, actionTitle: "Try Again") {
                    Task { await run() }
                }
            }
        }
        .task(id: id) { await run() }
    }

    private func run() async {
        if case .done = state {} else { state = .loading }
        do {
            let v = try await load()
            if !Task.isCancelled { state = .done(v) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }
}

/// Brief message at the bottom of the screen ("Added to My List").
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.body(26, weight: .semibold))
            .foregroundStyle(C.text)
            .padding(.horizontal, 34).padding(.vertical, 20)
            .background(C.surface3, in: Capsule())
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
