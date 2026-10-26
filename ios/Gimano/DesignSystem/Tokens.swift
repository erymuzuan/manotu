import SwiftUI
import UIKit

/// Gimano "Cobalt" design tokens. Mirrors docs/design-tokens.md (shared with Android `GimanoTokens.kt`).
/// Guiding rule: big icons, little text.
enum Tokens {
    enum Palette {
        static let brand = dynamic(light: 0x0047AB, dark: 0x5B8DEF)
        static let brandOn = dynamic(light: 0xFFFFFF, dark: 0x071430)
        static let brandInk = dynamic(light: 0x0A2E6E, dark: 0xBFD3F7)
        static let brandTint = dynamic(light: 0x8FB0E8, dark: 0x3A5A99)
        static let brandMist = dynamic(light: 0xE3ECFA, dark: 0x16233D)
        static let report = dynamic(light: 0xFF6B4A, dark: 0xFF8266)
        static let reportOn = dynamic(light: 0xFFFFFF, dark: 0x2A0A03)
        static let reportTint = dynamic(light: 0xFFD3C7, dark: 0x7A2E1C)
        static let background = dynamic(light: 0xF5F8FD, dark: 0x0B1220)
        static let surface = dynamic(light: 0xFFFFFF, dark: 0x121B2E)
        static let surfaceAlt = dynamic(light: 0xEEF3FC, dark: 0x1A2540)
        static let outline = dynamic(light: 0xC9D6EE, dark: 0x2A3A5C)
        static let text = dynamic(light: 0x0B1B3A, dark: 0xEEF3FC)
        static let textMuted = dynamic(light: 0x3A4A66, dark: 0xA9B6CF)
        static let navBanner = UIColor(hex: 0x0A1F4D)
        static let navBannerOn = UIColor(hex: 0xFFFFFF)
        static let routeActive = dynamic(light: 0x0047AB, dark: 0x5B8DEF)
        static let routeAlt = dynamic(light: 0xA9C2EE, dark: 0x2F4777)
        static let traffic1 = UIColor(hex: 0xF5C518)
        static let traffic2 = UIColor(hex: 0xFFB020)
        static let traffic3 = UIColor(hex: 0xE5484D)
        static let traffic4 = UIColor(hex: 0x7F1D1D)
        static let speeding = UIColor(hex: 0xE5484D)
        static let mapBackground = dynamic(light: 0xEEF2F8, dark: 0x0E1626)

        static func traffic(level: Int) -> UIColor {
            switch level {
            case ...1: traffic1
            case 2: traffic2
            case 3: traffic3
            default: traffic4
            }
        }

        private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
        }
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let pill: CGFloat = 999
        static let menuFab: CGFloat = 22
        static let reportFab: CGFloat = 28
        static let searchField: CGFloat = 22
        static let shortcutTile: CGFloat = 24
        static let reportTile: CGFloat = 32
        static let sheetTop: CGFloat = 28
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let gutter: CGFloat = 16
        static let gridGap: CGFloat = 12
    }

    enum Size {
        static let fab: CGFloat = 64
        static let fabIcon: CGFloat = 30
        static let reportFab: CGFloat = 84
        static let reportFabIcon: CGFloat = 46
        static let searchField: CGFloat = 64
        static let searchIcon: CGFloat = 30
        static let shortcutTile: CGFloat = 76
        static let shortcutIcon: CGFloat = 42
        static let reportTile: CGFloat = 104
        static let reportIcon: CGFloat = 60
        static let speedometer: CGFloat = 72
        static let handle = CGSize(width: 40, height: 5)
    }

    /// Nunito (SIL OFL), bundled variable font with named instances.
    enum Font {
        static func nunito(_ size: CGFloat, _ weight: Weight = .semibold, relativeTo style: SwiftUI.Font.TextStyle = .body) -> SwiftUI.Font {
            .custom(weight.postScriptName, size: size, relativeTo: style)
        }

        enum Weight {
            case regular, semibold, bold, extrabold, black
            var postScriptName: String {
                switch self {
                case .regular: "Nunito-Regular"
                case .semibold: "Nunito-SemiBold"
                case .bold: "Nunito-Bold"
                case .extrabold: "Nunito-ExtraBold"
                case .black: "Nunito-Black"
                }
            }
        }

        static let navDistance = nunito(44, .black, relativeTo: .largeTitle)
        static let etaClock = nunito(34, .extrabold, relativeTo: .largeTitle)
        static let title = nunito(22, .extrabold, relativeTo: .title2)
        static let body = nunito(17, .semibold)
        static let bodyBold = nunito(17, .extrabold)
        static let label = nunito(14, .extrabold, relativeTo: .footnote)
        static let caption = nunito(14, .semibold, relativeTo: .footnote)
        static let small = nunito(12, .semibold, relativeTo: .caption)
        static let button = nunito(17, .extrabold)
    }
}

extension Color {
    static let brand = Color(uiColor: Tokens.Palette.brand)
    static let brandOn = Color(uiColor: Tokens.Palette.brandOn)
    static let brandInk = Color(uiColor: Tokens.Palette.brandInk)
    static let brandTint = Color(uiColor: Tokens.Palette.brandTint)
    static let brandMist = Color(uiColor: Tokens.Palette.brandMist)
    static let report = Color(uiColor: Tokens.Palette.report)
    static let reportOn = Color(uiColor: Tokens.Palette.reportOn)
    static let reportTint = Color(uiColor: Tokens.Palette.reportTint)
    static let appBackground = Color(uiColor: Tokens.Palette.background)
    static let surface = Color(uiColor: Tokens.Palette.surface)
    static let surfaceAlt = Color(uiColor: Tokens.Palette.surfaceAlt)
    static let outline = Color(uiColor: Tokens.Palette.outline)
    static let textPrimary = Color(uiColor: Tokens.Palette.text)
    static let textMuted = Color(uiColor: Tokens.Palette.textMuted)
    static let navBanner = Color(uiColor: Tokens.Palette.navBanner)
    static let navBannerOn = Color(uiColor: Tokens.Palette.navBannerOn)
    static let routeActive = Color(uiColor: Tokens.Palette.routeActive)
    static let routeAlt = Color(uiColor: Tokens.Palette.routeAlt)
    static let speeding = Color(uiColor: Tokens.Palette.speeding)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// FAB shadow: 0 3 10 rgba(11,27,58,.16)
    func fabShadow() -> some View {
        shadow(color: Color(red: 11 / 255, green: 27 / 255, blue: 58 / 255).opacity(0.16), radius: 5, x: 0, y: 3)
    }

    /// Report FAB shadow: 0 6 16 rgba(255,107,74,.45)
    func reportShadow() -> some View {
        shadow(color: Color(red: 1, green: 107 / 255, blue: 74 / 255).opacity(0.45), radius: 8, x: 0, y: 6)
    }
}

extension Color {
    /// A light/dark pair for one-off tints (board colours that aren't palette tokens).
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    // Status tints from the "More screens" boards.
    static let tealMist = Color(light: 0xDDF4F2, dark: 0x0F2E2C)
    static let tealInk = Color(light: 0x0E5A54, dark: 0x8FE0D8)
    static let amberMist = Color(light: 0xFFF1CC, dark: 0x3A2E12)
    static let amberInk = Color(light: 0x7A5200, dark: 0xF5D27A)
    /// Warning banner border (content safety).
    static let amberEdge = Color(light: 0xFFD466, dark: 0x6B5420)
    static let coralMist = Color(light: 0xFFE4DC, dark: 0x3A1A12)
}

extension View {
    /// Big selectable tile (Cobalt boards): pale fill always; the selected one gets a cobalt border, not a solid fill.
    func selectableTile(_ selected: Bool, radius: CGFloat, tint: Color = .brandMist, width: CGFloat = 2) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(tint, in: shape)
            .overlay(shape.strokeBorder(Color.brand, lineWidth: selected ? width : 0))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
