import SwiftUI
import UIKit

/// Ember's colours, matching the design canvas and `lib/ui/theme.dart`.
enum C {
    static let bg = Color(hex: 0x0A0A0B)
    static let surface = Color(hex: 0x141416)
    static let surface2 = Color(hex: 0x1E1E22)
    static let surface3 = Color(hex: 0x2A2A2F)
    static let text = Color(hex: 0xF4F1EC)
    static let soft = Color(hex: 0xD9D4CC)
    static let muted = Color(hex: 0xB9B4AC)
    static let faint = Color(hex: 0x8E8982)
    static let accent = Color(hex: 0xFF7A2F)
    static let accentInk = Color(hex: 0x1A0E05)
    static let accentDark = Color(hex: 0x2A1A10)
    static let good = Color(hex: 0x7BD88F)
    static let warn = Color(hex: 0xF2D27A)
    static let bad = Color(hex: 0xF0A0A0)
    static let blue = Color(hex: 0x9CC3F0)
    static let ink = Color(hex: 0x111111)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Sizes are in points on a 1920×1080 screen, which is what tvOS uses on every Apple TV
/// (4K TVs simply get sharper pixels), so the numbers match the design mockups exactly.
enum Metrics {
    static let menuCollapsed: CGFloat = 112
    static let menuOpen: CGFloat = 470
    static let gutter: CGFloat = 80
    static let tileWidth: CGFloat = 384
    static let tileHeight: CGFloat = 216
    static let tileRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 12
}

extension Font {
    /// Titles: Bricolage Grotesque.
    static func display(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        let name = weight == .semibold ? "BricolageGrotesque-SemiBold" : "BricolageGrotesque-ExtraBold"
        return .custom(name, fixedSize: size)
    }

    /// Everything else: Figtree.
    static func body(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .regular, .light, .thin, .ultraLight: name = "Figtree-Regular"
        case .semibold: name = "Figtree-SemiBold"
        case .bold: name = "Figtree-Bold"
        case .heavy, .black: name = "Figtree-ExtraBold"
        default: name = "Figtree-Medium"
        }
        return .custom(name, fixedSize: size)
    }
}

extension View {
    /// Display titles are set slightly tight, like the design (−2.5 %).
    func displayTracking(_ size: CGFloat) -> some View { tracking(-size * 0.025) }

    /// Small uppercase label in the accent colour ("FILM · NEW IN YOUR LIBRARY").
    func eyebrow() -> some View {
        font(.body(20, weight: .bold)).tracking(4).foregroundStyle(C.accent).textCase(.uppercase)
    }
}

/// The gradients that keep text readable over artwork.
struct Scrim: View {
    var leading = true
    var bottom = true
    var body: some View {
        ZStack {
            if leading {
                LinearGradient(stops: [
                    .init(color: C.bg, location: 0),
                    .init(color: C.bg.opacity(0.85), location: 0.38),
                    .init(color: C.bg.opacity(0), location: 0.75),
                ], startPoint: .leading, endPoint: .trailing)
            }
            if bottom {
                LinearGradient(stops: [
                    .init(color: C.bg, location: 0),
                    .init(color: C.bg.opacity(0), location: 0.45),
                ], startPoint: .bottom, endPoint: .top)
            }
        }
        .allowsHitTesting(false)
    }
}
