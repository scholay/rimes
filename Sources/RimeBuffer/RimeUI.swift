import Cocoa
import QuartzCore

enum RimeThemeFamily: String, CaseIterable {
    case classic
    case rasta
    case apple

    var title: String {
        switch self {
        case .classic: return "经典"
        case .rasta: return "拉斯塔"
        case .apple: return "Apple"
        }
    }
}

/// A concrete colorway. `night`, `day`, and `quiet` intentionally preserve
/// their historical raw values: they are now the three colorways of the
/// Classic theme rather than three unrelated themes.
enum RimeAppearanceMode: String, CaseIterable {
    case night
    case day
    case quiet
    case rasta
    case liquidGlass

    var title: String {
        switch self {
        case .night: return "墨竹"
        case .day: return "翡翠"
        case .quiet: return "静谧"
        case .rasta: return "拉斯塔"
        case .liquidGlass: return "Liquid Glass"
        }
    }

    var family: RimeThemeFamily {
        switch self {
        case .night, .day, .quiet: return .classic
        case .rasta: return .rasta
        case .liquidGlass: return .apple
        }
    }

    var selectionTitle: String {
        switch family {
        case .classic: return "经典 · \(title)"
        case .rasta: return title
        case .apple: return "Apple · \(title)"
        }
    }

    var detailText: String {
        switch self {
        case .night: return "经典深色配色，层级清晰，适合长时间输入。"
        case .day: return "经典浅色配色，柔和边界与固定产品绿。"
        case .quiet: return "经典去色配色，降低视觉刺激。"
        case .rasta: return "深色精致骨架，以红、黄、绿三色共同组织状态与操作。"
        case .liquidGlass: return "跟随系统明暗，使用液态玻璃材质；旧系统使用半透明材质，减少透明度时使用实色。"
        }
    }

    var usesDarkSurfaces: Bool {
        switch self {
        case .night, .quiet, .rasta: return true
        case .day: return false
        case .liquidGlass:
            return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var palette: RimeThemePalette {
        switch self {
        case .night: return RimeThemePalettes.night
        case .day: return RimeThemePalettes.day
        case .quiet: return RimeThemePalettes.quiet
        case .rasta: return RimeThemePalettes.rasta
        // Keep the product accents and readable opaque fallbacks while the
        // material follows the system light/dark appearance.
        case .liquidGlass: return usesDarkSurfaces ? RimeThemePalettes.night : RimeThemePalettes.day
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
        case (.rasta, false): return .darkAqua
        case (.rasta, true): return .accessibilityHighContrastDarkAqua
        // RimeUI.appKitAppearance intentionally returns nil for Liquid Glass
        // so the system appearance drives the native material.
        case (.liquidGlass, false): return usesDarkSurfaces ? .darkAqua : .aqua
        case (.liquidGlass, true): return usesDarkSurfaces ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        }
    }
}

extension Notification.Name {
    static let rimeAppearanceDidChange = Notification.Name("RimeAppearanceDidChange")
}

struct RimeThemePalette {
    let accentBlue: UInt32
    let accentGreen: UInt32
    let accentSecondary: UInt32
    let accentTertiary: UInt32
    let brandRed: UInt32
    let brandYellow: UInt32
    let brandGreen: UInt32
    let settingsBackground: UInt32
    let settingsSeparator: UInt32
    let bufferBackground: UInt32
    let bufferBackgroundSecondary: UInt32
    let bufferBorder: UInt32
    let bufferDivider: UInt32
    let bufferSourceRail: UInt32
    let bufferTargetRail: UInt32
    let bufferChip: UInt32
    let bufferChipSelected: UInt32
    let bufferPreedit: UInt32
    let bufferMuted: UInt32
    let clipboardSelected: UInt32
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
    let warningText: UInt32
    let warningSurface: UInt32
    let warningBorder: UInt32
    let dangerText: UInt32
    let dangerFill: UInt32
    let dangerForeground: UInt32
    let dangerBorder: UInt32

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
        accentSecondary: 0xEAB308,
        accentTertiary: 0xEF4444,
        brandRed: 0xEF4444,
        brandYellow: 0xEAB308,
        brandGreen: productGreen,
        settingsBackground: 0x323232,
        settingsSeparator: 0x464646,
        bufferBackground: 0x0C1E33,
        bufferBackgroundSecondary: 0x123458,
        bufferBorder: 0x2C5A8C,
        bufferDivider: 0x3A4C5D,
        bufferSourceRail: 0x15191F,
        bufferTargetRail: 0x122A21,
        bufferChip: 0x143A27,
        bufferChipSelected: 0x165030,
        bufferPreedit: 0x165030,
        bufferMuted: 0x9AA2AE,
        clipboardSelected: 0x1A4430,
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
        candidateBackground: 0x101318,
        warningText: 0xFF9230,
        warningSurface: 0x332923,
        warningBorder: 0x946D32,
        dangerText: 0xFF4245,
        dangerFill: 0xA63A3A,
        dangerForeground: 0xFFFFFF,
        dangerBorder: 0x8E2E2E
    )

    // Product-owned 翡翠 surfaces use fixed sRGB values. AppKit semantic
    // colors can otherwise resolve for the system appearance, which may be
    // dark even while ETInput is explicitly using this light theme.
    static let day = RimeThemePalette(
        accentBlue: productGreen,
        accentGreen: productGreen,
        accentSecondary: 0xA16207,
        accentTertiary: 0xB42318,
        brandRed: 0xB42318,
        brandYellow: 0xA16207,
        brandGreen: productGreen,
        settingsBackground: 0xECECEC,
        settingsSeparator: 0xD5D5D5,
        bufferBackground: 0xF1F6FC,
        bufferBackgroundSecondary: 0xE4EEF9,
        bufferBorder: 0x8298B0,
        bufferDivider: 0xB1B9C5,
        bufferSourceRail: 0xF0F4F7,
        bufferTargetRail: 0xE7F6EF,
        bufferChip: 0xDAF3E6,
        bufferChipSelected: 0xC5EDD6,
        bufferPreedit: 0xC9EED9,
        bufferMuted: 0x4B5563,
        clipboardSelected: 0xCDEBDE,
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
        candidateBackground: 0xF8FAFC,
        warningText: 0x8A4B00,
        warningSurface: 0xFFF4E5,
        warningBorder: 0xA15C00,
        dangerText: 0xB42318,
        dangerFill: 0xA63A3A,
        dangerForeground: 0xFFFFFF,
        dangerBorder: 0x8E2E2E
    )

    /// A deliberately chroma-free dark palette. Accent surfaces are light
    /// enough to remain readable as status text; controls choose their black
    /// or white foreground from `accentForeground` instead of assuming white.
    static let quiet = RimeThemePalette(
        accentBlue: 0xA3A3A3,
        accentGreen: 0xA3A3A3,
        accentSecondary: 0xD4D4D4,
        accentTertiary: 0x737373,
        brandRed: 0x737373,
        brandYellow: 0xD4D4D4,
        brandGreen: 0xA3A3A3,
        settingsBackground: 0x323232,
        settingsSeparator: 0x464646,
        bufferBackground: 0x111111,
        bufferBackgroundSecondary: 0x1C1C1C,
        bufferBorder: 0x6B6B6B,
        bufferDivider: 0x474747,
        bufferSourceRail: 0x191919,
        bufferTargetRail: 0x272727,
        bufferChip: 0x333333,
        bufferChipSelected: 0x454545,
        bufferPreedit: 0x454545,
        bufferMuted: 0xA3A3A3,
        clipboardSelected: 0x3C3C3C,
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
        candidateBackground: 0x141414,
        warningText: 0xFF9230,
        warningSurface: 0x35291F,
        warningBorder: 0x946D32,
        dangerText: 0xFF4245,
        dangerFill: 0xA63A3A,
        dangerForeground: 0xFFFFFF,
        dangerBorder: 0x8E2E2E
    )

    /// A deliberately dark, layered palette. Green owns input/caret, yellow
    /// owns configuration/navigation, and red owns terminal/destructive
    /// actions. The workbench chrome also renders all three as one restrained
    /// inset accent rail so Rasta is a theme, not a single-color skin.
    static let rasta = RimeThemePalette(
        accentBlue: 0x35B85A,
        accentGreen: 0x35B85A,
        accentSecondary: 0xF2C94C,
        accentTertiary: 0xE5524A,
        brandRed: 0xE5524A,
        brandYellow: 0xF2C94C,
        brandGreen: 0x35B85A,
        settingsBackground: 0x211F1B,
        settingsSeparator: 0x3C382F,
        bufferBackground: 0x171713,
        bufferBackgroundSecondary: 0x222119,
        bufferBorder: 0x6F653B,
        bufferDivider: 0x514B2F,
        bufferSourceRail: 0x1D211B,
        bufferTargetRail: 0x272316,
        bufferChip: 0x213A27,
        bufferChipSelected: 0x2C5133,
        bufferPreedit: 0x29472E,
        bufferMuted: 0xB8AD91,
        clipboardSelected: 0x34321E,
        surface: 0x141511,
        surfaceSecondary: 0x20211B,
        surfaceTertiary: 0x2A2A21,
        border: 0x3B3A2D,
        borderStrong: 0x756E4F,
        textPrimary: 0xF7F3E8,
        textSecondary: 0xCEC7B2,
        textMuted: 0xA79F88,
        selectedCandidateBackground: 0x287F42,
        selectedCandidateText: 0xFFFFFF,
        candidateBackground: 0x151610,
        warningText: 0xF2C94C,
        warningSurface: 0x332D18,
        warningBorder: 0x8A742E,
        dangerText: 0xFF766E,
        dangerFill: 0xA33E38,
        dangerForeground: 0xFFFFFF,
        dangerBorder: 0xCC5149
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
    private static let systemAppearanceObservation = RimeSystemAppearanceObservation()
    private static let appearanceKey = "appearanceMode"
    private static let lastClassicAppearanceKey = "appearanceMode.classic.last.v1"

    static var appearance: RimeAppearanceMode {
        get {
            // Development renderers can exercise every theme without
            // mutating the user's persisted preference domain.
            // Read only this override, not a newly bridged dictionary of the
            // entire process environment for every color/width lookup. Keep
            // it dynamic for the in-process theme renderers.
            if let raw = getenv("RIMEBUFFER_APPEARANCE_MODE"),
               let mode = RimeAppearanceMode(rawValue: String(cString: raw)) {
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
            if newValue.family == .classic {
                UserDefaults.standard.set(
                    newValue.rawValue,
                    forKey: lastClassicAppearanceKey
                )
            }
            NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
        }
    }

    static var lastClassicAppearance: RimeAppearanceMode {
        guard let raw = UserDefaults.standard.string(
            forKey: lastClassicAppearanceKey
        ), let mode = RimeAppearanceMode(rawValue: raw),
        mode.family == .classic else {
            return appearance.family == .classic ? appearance : .night
        }
        return mode
    }

    static func selectThemeFamily(_ family: RimeThemeFamily) {
        switch family {
        case .classic: appearance = lastClassicAppearance
        case .rasta: appearance = .rasta
        case .apple: appearance = .liquidGlass
        }
    }

    static var isLiquidGlass: Bool { appearance == .liquidGlass }
    static var usesLiquidGlassTransparency: Bool {
        isLiquidGlass
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var isDark: Bool { appearance.usesDarkSurfaces }
    static var themeFamily: RimeThemeFamily { appearance.family }
    static var isRasta: Bool { themeFamily == .rasta }

    static var palette: RimeThemePalette {
        appearance.palette
    }

    static var appKitAppearance: NSAppearance? {
        _ = systemAppearanceObservation
        guard !isLiquidGlass else { return nil }
        let name = appearance.appKitAppearanceName(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        return NSAppearance(named: name)
    }

    static var accentBlue: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentBlue) }
    static var accentGreen: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentGreen) }
    static var accentSecondary: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentSecondary) }
    static var accentTertiary: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentTertiary) }
    static var brandRed: NSColor { color(palette.brandRed) }
    static var brandYellow: NSColor { color(palette.brandYellow) }
    static var brandGreen: NSColor { color(palette.brandGreen) }
    static var accentForegroundColor: NSColor {
        guard isLiquidGlass,
              let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return color(palette.accentForeground)
        }
        let hex = (UInt32((accent.redComponent * 255).rounded()) << 16)
            | (UInt32((accent.greenComponent * 255).rounded()) << 8)
            | UInt32((accent.blueComponent * 255).rounded())
        return color(RimeColorContrast.preferredForeground(background: hex))
    }
    static var accentTextColor: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentText) }
    static var bufferBg: NSColor { isLiquidGlass ? .windowBackgroundColor : color(palette.bufferBackground) }
    static var bufferBg2: NSColor { isLiquidGlass ? .controlBackgroundColor : color(palette.bufferBackgroundSecondary) }
    static var bufferBorder: NSColor { isLiquidGlass ? glassBorder : color(palette.bufferBorder) }
    static var bufferDivider: NSColor { isLiquidGlass ? glassBorder : color(palette.bufferDivider) }
    static var bufferSourceRail: NSColor {
        isLiquidGlass ? NSColor.controlBackgroundColor.withAlphaComponent(
            usesLiquidGlassTransparency ? 0.18 : 1) : color(palette.bufferSourceRail)
    }
    static var bufferTargetRail: NSColor {
        isLiquidGlass ? NSColor.controlBackgroundColor.withAlphaComponent(
            usesLiquidGlassTransparency ? 0.18 : 1) : color(palette.bufferTargetRail)
    }
    static var bufferChip: NSColor { isLiquidGlass ? .controlBackgroundColor : color(palette.bufferChip) }
    static var bufferChipSelected: NSColor { isLiquidGlass ? NSColor.controlAccentColor.withAlphaComponent(0.18) : color(palette.bufferChipSelected) }
    static var bufferPreedit: NSColor { isLiquidGlass ? NSColor.controlAccentColor.withAlphaComponent(0.14) : color(palette.bufferPreedit) }
    static var bufferMuted: NSColor { isLiquidGlass ? .secondaryLabelColor : color(palette.bufferMuted) }
    static var clipboardSelectedBackground: NSColor {
        isLiquidGlass ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : color(palette.clipboardSelected)
    }
    static var surface: NSColor { isLiquidGlass ? .windowBackgroundColor : color(palette.surface) }
    static var surface2: NSColor { isLiquidGlass ? .controlBackgroundColor : color(palette.surfaceSecondary) }
    static var surface3: NSColor { isLiquidGlass ? .underPageBackgroundColor : color(palette.surfaceTertiary) }
    static var workbenchChrome: NSColor { isLiquidGlass ? .windowBackgroundColor : color(palette.bufferBackground) }
    // Existing controls adjust border opacity for hover/disabled states. Resolve
    // the system separator against its surface first so those adjustments do not
    // turn AppKit's translucent black separator into an opaque black outline.
    private static var glassBorder: NSColor {
        let separator = NSColor.separatorColor.usingColorSpace(.sRGB) ?? .separatorColor
        return NSColor.windowBackgroundColor.blended(
            withFraction: separator.alphaComponent,
            of: separator.withAlphaComponent(1)
        ) ?? .separatorColor
    }
    static var border: NSColor { isLiquidGlass ? glassBorder : color(palette.border) }
    static var borderStrong: NSColor { isLiquidGlass ? glassBorder : color(palette.borderStrong) }
    static var textPrimary: NSColor { isLiquidGlass ? .labelColor : color(palette.textPrimary) }
    static var textSecondary: NSColor { isLiquidGlass ? .secondaryLabelColor : color(palette.textSecondary) }
    static var textMuted: NSColor { isLiquidGlass ? .tertiaryLabelColor : color(palette.textMuted) }
    static var selectedCandidateBackgroundColor: NSColor {
        isLiquidGlass ? .selectedContentBackgroundColor : color(palette.selectedCandidateBackground)
    }
    static var selectedCandidateTextColor: NSColor {
        isLiquidGlass ? .alternateSelectedControlTextColor : color(palette.selectedCandidateText)
    }
    static var candidateBackgroundColor: NSColor { isLiquidGlass ? .windowBackgroundColor : color(palette.candidateBackground) }
    static var warningTextColor: NSColor { color(palette.warningText) }
    static var warningSurfaceColor: NSColor { color(palette.warningSurface) }
    static var warningBorderColor: NSColor { color(palette.warningBorder) }
    static var dangerTextColor: NSColor { color(palette.dangerText) }
    static var dangerFillColor: NSColor { color(palette.dangerFill) }
    static var dangerForegroundColor: NSColor { color(palette.dangerForeground) }
    static var dangerBorderColor: NSColor { color(palette.dangerBorder) }

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
