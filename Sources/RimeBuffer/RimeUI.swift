import Cocoa
import QuartzCore

enum RimeAppearanceMode: String, CaseIterable {
    case night
    case day

    var title: String {
        switch self {
        case .night: return "夜间模式"
        case .day: return "日间模式"
        }
    }

    func appKitAppearanceName(increasedContrast: Bool) -> NSAppearance.Name {
        switch (self, increasedContrast) {
        case (.night, false): return .darkAqua
        case (.night, true): return .accessibilityHighContrastDarkAqua
        case (.day, false): return .aqua
        case (.day, true): return .accessibilityHighContrastAqua
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
}

enum RimeThemePalettes {
    static let night = RimeThemePalette(
        accentBlue: 0x3B82F6,
        accentGreen: 0x22C55E,
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

    // Product-owned light surfaces use fixed sRGB values. AppKit semantic
    // colors and the user's accent can resolve for the system appearance,
    // which may be dark even while ETInput is explicitly in day mode.
    static let day = RimeThemePalette(
        accentBlue: 0x1D5FA7,
        accentGreen: 0x0F6A3F,
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
            if let raw = UserDefaults.standard.string(forKey: appearanceKey),
               let mode = RimeAppearanceMode(rawValue: raw) {
                return mode
            }
            return .night
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey)
            NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
        }
    }

    static var isNight: Bool { appearance == .night }

    static var palette: RimeThemePalette {
        isNight ? RimeThemePalettes.night : RimeThemePalettes.day
    }

    static var appKitAppearance: NSAppearance? {
        let name = appearance.appKitAppearanceName(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        return NSAppearance(named: name)
    }

    static var accentBlue: NSColor { color(palette.accentBlue) }
    static var accentGreen: NSColor { color(palette.accentGreen) }
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
