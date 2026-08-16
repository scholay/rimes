import Cocoa
import QuartzCore

enum RimeAppearanceMode: String, CaseIterable {
    case night
    case day
    case quiet

    var title: String {
        switch self {
        case .night: return "墨竹"
        case .day: return "翡翠"
        case .quiet: return "静谧"
        }
    }

    var usesDarkSurfaces: Bool {
        switch self {
        case .night, .quiet: return true
        case .day: return false
        }
    }

    var palette: RimeThemePalette {
        switch self {
        case .night: return RimeThemePalettes.night
        case .day: return RimeThemePalettes.day
        case .quiet: return RimeThemePalettes.quiet
        }
    }

    func appKitAppearanceName(increasedContrast: Bool) -> NSAppearance.Name {
        switch (self, increasedContrast) {
        case (.night, false): return .darkAqua
        case (.night, true): return .accessibilityHighContrastDarkAqua
        case (.day, false): return .aqua
        case (.day, true): return .accessibilityHighContrastAqua
        case (.quiet, false): return .darkAqua
        case (.quiet, true): return .accessibilityHighContrastDarkAqua
        }
    }
}

extension Notification.Name {
    static let rimeAppearanceDidChange = Notification.Name("RimeAppearanceDidChange")
}

struct RimeThemePalette {
    let accentBlue: UInt32
    let accentGreen: UInt32
    let bufferBackground: UInt32
    let bufferBackgroundSecondary: UInt32
    let bufferBorder: UInt32
    let surface: UInt32
    let surfaceSecondary: UInt32
    let surfaceTertiary: UInt32
    let border: UInt32
    let borderStrong: UInt32
    let textPrimary: UInt32
    let textSecondary: UInt32
    let textMuted: UInt32
    let selectedCandidateBackground: UInt32
    let selectedCandidateText: UInt32
    let candidateBackground: UInt32

    var accentForeground: UInt32 {
        RimeColorContrast.preferredForeground(background: accentGreen)
    }

    /// Small status copy needs normal-text contrast. The bright accent works
    /// on dark themes; light themes fall back to their deeper selection tone.
    var accentText: UInt32 {
        RimeColorContrast.ratio(
            foreground: accentGreen,
            background: surfaceSecondary
        ) >= 4.5 ? accentGreen : selectedCandidateBackground
    }
}

enum RimeThemePalettes {
    /// 墨竹 and 翡翠 share the product green. 静谧 intentionally replaces it
    /// with a neutral accent, while every theme remains independent of the
    /// user's macOS accent preference. Keep the legacy `accentBlue` and
    /// `accentGreen` slots in sync inside each palette.
    static let productGreen: UInt32 = 0x22C55E

    static let night = RimeThemePalette(
        accentBlue: productGreen,
        accentGreen: productGreen,
        bufferBackground: 0x0C1E33,
        bufferBackgroundSecondary: 0x123458,
        bufferBorder: 0x2C5A8C,
        surface: 0x101318,
        surfaceSecondary: 0x171B22,
        surfaceTertiary: 0x1E232C,
        border: 0x252A33,
        borderStrong: 0x607080,
        textPrimary: 0xF3F5F8,
        textSecondary: 0x9AA2AE,
        textMuted: 0x838B98,
        selectedCandidateBackground: 0x15803D,
        selectedCandidateText: 0xFFFFFF,
        candidateBackground: 0x101318
    )

    // Product-owned 翡翠 surfaces use fixed sRGB values. AppKit semantic
    // colors can otherwise resolve for the system appearance, which may be
    // dark even while ETInput is explicitly using this light theme.
    static let day = RimeThemePalette(
        accentBlue: productGreen,
        accentGreen: productGreen,
        bufferBackground: 0xF1F6FC,
        bufferBackgroundSecondary: 0xE4EEF9,
        bufferBorder: 0x8298B0,
        surface: 0xF5F7FA,
        surfaceSecondary: 0xEEF2F6,
        surfaceTertiary: 0xE7ECF2,
        border: 0xC9D2DE,
        borderStrong: 0x7C8797,
        textPrimary: 0x17202B,
        textSecondary: 0x334155,
        textMuted: 0x4B5563,
        selectedCandidateBackground: 0x0F6A3F,
        selectedCandidateText: 0xFFFFFF,
        candidateBackground: 0xF8FAFC
    )

    /// A deliberately chroma-free dark palette. Accent surfaces are light
    /// enough to remain readable as status text; controls choose their black
    /// or white foreground from `accentForeground` instead of assuming white.
    static let quiet = RimeThemePalette(
        accentBlue: 0xA3A3A3,
        accentGreen: 0xA3A3A3,
        bufferBackground: 0x111111,
        bufferBackgroundSecondary: 0x1C1C1C,
        bufferBorder: 0x6B6B6B,
        surface: 0x141414,
        surfaceSecondary: 0x1B1B1B,
        surfaceTertiary: 0x252525,
        border: 0x3A3A3A,
        borderStrong: 0x737373,
        textPrimary: 0xF5F5F5,
        textSecondary: 0xC7C7C7,
        textMuted: 0xA3A3A3,
        selectedCandidateBackground: 0x6B6B6B,
        selectedCandidateText: 0xFFFFFF,
        candidateBackground: 0x141414
    )
}

/// Pure WCAG contrast math used by the CLI smoke test. Keeping the source
/// palette as hex makes the test independent of the current macOS appearance.
enum RimeColorContrast {
    static func ratio(foreground: UInt32,
                      alpha: Double = 1,
                      background: UInt32) -> Double {
        let foregroundRGB = components(foreground)
        let backgroundRGB = components(background)
        let opacity = min(max(alpha, 0), 1)
        let composite = (
            foregroundRGB.0 * opacity + backgroundRGB.0 * (1 - opacity),
            foregroundRGB.1 * opacity + backgroundRGB.1 * (1 - opacity),
            foregroundRGB.2 * opacity + backgroundRGB.2 * (1 - opacity)
        )
        let lighter = max(luminance(composite), luminance(backgroundRGB))
        let darker = min(luminance(composite), luminance(backgroundRGB))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Choose the higher-contrast monochrome foreground for any opaque theme
    /// color. One of black/white always clears WCAG AA for normal text, so a
    /// future palette change cannot make selected candidate text disappear.
    static func preferredForeground(background: UInt32) -> UInt32 {
        let light: UInt32 = 0xFFFFFF
        let dark: UInt32 = 0x000000
        return ratio(foreground: light, background: background)
            >= ratio(foreground: dark, background: background)
            ? light
            : dark
    }

    private static func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xff) / 255,
         Double((hex >> 8) & 0xff) / 255,
         Double(hex & 0xff) / 255)
    }

    private static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(rgb.0)
            + 0.7152 * linearize(rgb.1)
            + 0.0722 * linearize(rgb.2)
    }
}

enum RimeUI {
    private static let appearanceKey = "appearanceMode"

    static var appearance: RimeAppearanceMode {
        get {
            // Development renderers can exercise every theme without
            // mutating the user's persisted preference domain.
            if let raw = ProcessInfo.processInfo.environment["RIMEBUFFER_APPEARANCE_MODE"],
               let mode = RimeAppearanceMode(rawValue: raw) {
                return mode
            }
            if let raw = UserDefaults.standard.string(forKey: appearanceKey),
               let mode = RimeAppearanceMode(rawValue: raw) {
                return mode
            }
            return .night
        }
        set {
            // Compare against persisted state, not the development-only
            // environment override. A preview process may force one palette,
            // but must not make a real preference write appear successful
            // when the stored value is different.
            let stored = UserDefaults.standard.string(forKey: appearanceKey)
                .flatMap(RimeAppearanceMode.init(rawValue:)) ?? .night
            guard newValue != stored else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
            NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
        }
    }

    static var isDark: Bool { appearance.usesDarkSurfaces }

    static var palette: RimeThemePalette {
        appearance.palette
    }

    static var appKitAppearance: NSAppearance? {
        let name = appearance.appKitAppearanceName(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        return NSAppearance(named: name)
    }

    static var accentBlue: NSColor { color(palette.accentBlue) }
    static var accentGreen: NSColor { color(palette.accentGreen) }
    static var accentForegroundColor: NSColor { color(palette.accentForeground) }
    static var accentTextColor: NSColor { color(palette.accentText) }
    static var bufferBg: NSColor { color(palette.bufferBackground) }
    static var bufferBg2: NSColor { color(palette.bufferBackgroundSecondary) }
    static var bufferBorder: NSColor { color(palette.bufferBorder) }
    static var surface: NSColor { color(palette.surface) }
    static var surface2: NSColor { color(palette.surfaceSecondary) }
    static var surface3: NSColor { color(palette.surfaceTertiary) }
    static var workbenchChrome: NSColor { color(palette.bufferBackground) }
    static var border: NSColor { color(palette.border) }
    static var borderStrong: NSColor { color(palette.borderStrong) }
    static var textPrimary: NSColor { color(palette.textPrimary) }
    static var textSecondary: NSColor { color(palette.textSecondary) }
    static var textMuted: NSColor { color(palette.textMuted) }
    static var selectedCandidateBackgroundColor: NSColor {
        color(palette.selectedCandidateBackground)
    }
    static var selectedCandidateTextColor: NSColor {
        color(palette.selectedCandidateText)
    }
    static var candidateBackgroundColor: NSColor { color(palette.candidateBackground) }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
    }
}

final class GradientPanelView: NSView {
    private let gradient = CAGradientLayer()
    private let radius: CGFloat

    init(colors: [NSColor], cornerRadius: CGFloat, borderColor: NSColor? = nil, borderWidth: CGFloat = 0) {
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.cornerRadius = cornerRadius
        gradient.masksToBounds = true
        gradient.borderColor = borderColor?.cgColor
        gradient.borderWidth = borderWidth
        layer = gradient
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        gradient.cornerRadius = radius
    }
}
