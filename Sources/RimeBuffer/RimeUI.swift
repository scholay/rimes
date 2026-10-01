import Cocoa
import QuartzCore

/// Shared translucency and edge values, matched to the MailGlass prototype.
enum RimeGlassPalette {
    static let panelFillOpacity: CGFloat = 0.05
    static let panelTintOpacity: CGFloat = 0.22
    static let edgeLineWidth: CGFloat = 0.6
    static let edgeHighlightOpacity: CGFloat = 0.24
    static let edgeShadowOpacity: CGFloat = 0.08
    static let edgeGlowOpacity: CGFloat = 0.10
    static let edgeGlowRadius: CGFloat = 1.2

    static var panelFill: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(panelFillOpacity)
    }

    static var panelTint: NSColor {
        NSColor.underPageBackgroundColor.withAlphaComponent(panelTintOpacity)
    }

    static var edgeHighlight: NSColor {
        NSColor.white.withAlphaComponent(edgeHighlightOpacity)
    }
}

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
        case .liquidGlass: return "使用 macOS 原生 Liquid Glass 候选材质；支持时，选中候选还会响应点击。"
        }
    }

    var usesDarkSurfaces: Bool {
        switch self {
        case .night, .quiet, .rasta: return true
        case .day: return false
        case .liquidGlass:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var palette: RimeThemePalette {
        switch self {
        case .night: return RimeThemePalettes.night
        case .day: return RimeThemePalettes.day
        case .quiet: return RimeThemePalettes.quiet
        case .rasta: return RimeThemePalettes.rasta
        // Glass uses semantic AppKit colors in RimeUI below; this palette is
        // only a safe fallback for older UI surfaces that still read hex slots.
        case .liquidGlass: return RimeThemePalettes.night
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
        case (.liquidGlass, false): return .aqua
        case (.liquidGlass, true): return .accessibilityHighContrastAqua
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
    private static let appearanceKey = "appearanceMode"
    private static let lastClassicAppearanceKey = "appearanceMode.classic.last.v1"

    static var appearance: RimeAppearanceMode {
        get {
            // Native preview and visual-smoke commands may force a legacy
            // colorway without changing the user's persisted Glass default.
            if let raw = ProcessInfo.processInfo.environment["RIMEBUFFER_APPEARANCE_MODE"],
               let mode = RimeAppearanceMode(rawValue: raw) {
                return mode
            }
            // Liquid Glass is the only supported product appearance. Rewrite
            // the former user preference on first access so upgrades converge
            // on the same default as a fresh install.
            if UserDefaults.standard.string(forKey: appearanceKey)
                != RimeAppearanceMode.liquidGlass.rawValue {
                UserDefaults.standard.set(
                    RimeAppearanceMode.liquidGlass.rawValue,
                    forKey: appearanceKey
                )
            }
            return .liquidGlass
        }
        set {
            guard newValue == .liquidGlass,
                  UserDefaults.standard.string(forKey: appearanceKey)
                    != RimeAppearanceMode.liquidGlass.rawValue else { return }
            UserDefaults.standard.set(
                RimeAppearanceMode.liquidGlass.rawValue,
                forKey: appearanceKey
            )
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

    static var isDark: Bool { appearance.usesDarkSurfaces }
    static var themeFamily: RimeThemeFamily { appearance.family }
    static var isRasta: Bool { themeFamily == .rasta }
    static var isLiquidGlass: Bool { appearance == .liquidGlass }
    static var usesLiquidGlassTransparency: Bool {
        isLiquidGlass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var palette: RimeThemePalette {
        appearance.palette
    }

    static var appKitAppearance: NSAppearance? {
        guard !isLiquidGlass else { return nil }
        let name = appearance.appKitAppearanceName(
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        return NSAppearance(named: name)
    }

    static var accentBlue: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentBlue) }
    static var accentGreen: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentGreen) }
    static var accentSecondary: NSColor { isLiquidGlass ? .systemYellow : color(palette.accentSecondary) }
    static var accentTertiary: NSColor { isLiquidGlass ? .systemRed : color(palette.accentTertiary) }
    static var brandRed: NSColor { color(palette.brandRed) }
    static var brandYellow: NSColor { color(palette.brandYellow) }
    static var brandGreen: NSColor { color(palette.brandGreen) }
    static var accentForegroundColor: NSColor { isLiquidGlass ? .labelColor : color(palette.accentForeground) }
    static var accentTextColor: NSColor { isLiquidGlass ? .controlAccentColor : color(palette.accentText) }
    static var bufferBg: NSColor {
        guard isLiquidGlass else { return color(palette.bufferBackground) }
        return usesLiquidGlassTransparency
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.08)
            : .windowBackgroundColor
    }
    static var bufferBg2: NSColor {
        guard isLiquidGlass else { return color(palette.bufferBackgroundSecondary) }
        return usesLiquidGlassTransparency
            ? NSColor.underPageBackgroundColor.withAlphaComponent(0.14)
            : .underPageBackgroundColor
    }
    static var bufferBorder: NSColor { isLiquidGlass ? .separatorColor : color(palette.bufferBorder) }
    static var bufferDivider: NSColor { isLiquidGlass ? .separatorColor : color(palette.bufferDivider) }
    static var bufferSourceRail: NSColor {
        usesLiquidGlassTransparency
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.20)
            : color(palette.bufferSourceRail)
    }
    static var bufferTargetRail: NSColor {
        usesLiquidGlassTransparency
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.20)
            : color(palette.bufferTargetRail)
    }
    static var bufferChip: NSColor { isLiquidGlass ? .quaternaryLabelColor : color(palette.bufferChip) }
    static var bufferChipSelected: NSColor { isLiquidGlass ? .controlAccentColor.withAlphaComponent(0.24) : color(palette.bufferChipSelected) }
    static var bufferPreedit: NSColor { isLiquidGlass ? .controlAccentColor.withAlphaComponent(0.20) : color(palette.bufferPreedit) }
    static var bufferMuted: NSColor { isLiquidGlass ? .secondaryLabelColor : color(palette.bufferMuted) }
    static var clipboardSelectedBackground: NSColor {
        isLiquidGlass ? NSColor.controlAccentColor.withAlphaComponent(0.22) : color(palette.clipboardSelected)
    }
    static var surface: NSColor {
        guard isLiquidGlass else { return color(palette.surface) }
        return usesLiquidGlassTransparency
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.08)
            : .windowBackgroundColor
    }
    static var surface2: NSColor {
        guard isLiquidGlass else { return color(palette.surfaceSecondary) }
        return usesLiquidGlassTransparency
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.20)
            : .controlBackgroundColor
    }
    static var surface3: NSColor {
        guard isLiquidGlass else { return color(palette.surfaceTertiary) }
        return usesLiquidGlassTransparency
            ? NSColor.underPageBackgroundColor.withAlphaComponent(0.16)
            : .underPageBackgroundColor
    }
    static var workbenchChrome: NSColor {
        guard isLiquidGlass else { return color(palette.bufferBackground) }
        return usesLiquidGlassTransparency
            ? NSColor.windowBackgroundColor.withAlphaComponent(0.10)
            : .windowBackgroundColor
    }
    static var border: NSColor { isLiquidGlass ? .separatorColor.withAlphaComponent(0.48) : color(palette.border) }
    static var borderStrong: NSColor { isLiquidGlass ? .separatorColor : color(palette.borderStrong) }
    static var textPrimary: NSColor { isLiquidGlass ? .labelColor : color(palette.textPrimary) }
    static var textSecondary: NSColor { isLiquidGlass ? .secondaryLabelColor : color(palette.textSecondary) }
    static var textMuted: NSColor { isLiquidGlass ? .tertiaryLabelColor : color(palette.textMuted) }
    static var selectedCandidateBackgroundColor: NSColor {
        isLiquidGlass ? NSColor.controlAccentColor.withAlphaComponent(0.30) : color(palette.selectedCandidateBackground)
    }
    static var selectedCandidateTextColor: NSColor {
        isLiquidGlass ? .labelColor : color(palette.selectedCandidateText)
    }
    /// Candidate selection follows the macOS accent used by Apple's input
    /// method, independent of the active RIMES colorway.
    static var candidateSelectionBackgroundColor: NSColor { .controlAccentColor }
    static var candidateSelectionTextColor: NSColor { .white }
    static var candidateBackgroundColor: NSColor { isLiquidGlass ? .clear : color(palette.candidateBackground) }
    static var warningTextColor: NSColor { isLiquidGlass ? .systemOrange : color(palette.warningText) }
    static var warningSurfaceColor: NSColor {
        isLiquidGlass
            ? NSColor.systemOrange.withAlphaComponent(0.12)
            : color(palette.warningSurface)
    }
    static var warningBorderColor: NSColor {
        isLiquidGlass
            ? NSColor.systemOrange.withAlphaComponent(0.45)
            : color(palette.warningBorder)
    }
    static var dangerTextColor: NSColor { isLiquidGlass ? .systemRed : color(palette.dangerText) }
    static var dangerFillColor: NSColor {
        isLiquidGlass
            ? NSColor.systemRed.withAlphaComponent(0.18)
            : color(palette.dangerFill)
    }
    static var dangerForegroundColor: NSColor { isLiquidGlass ? .white : color(palette.dangerForeground) }
    static var dangerBorderColor: NSColor {
        isLiquidGlass
            ? NSColor.systemRed.withAlphaComponent(0.55)
            : color(palette.dangerBorder)
    }

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

/// A small AppKit surface that switches between an ordinary themed fill and
/// Apple's native, untinted Liquid Glass. On systems before macOS 26 it uses
/// the standard vibrancy material as a compatible fallback.
final class RimeCandidateSurfaceView: NSView {
    let contentHost = NSView()

    private let fallbackVibrancy = NSVisualEffectView()
    private let glassEdgeOverlay = RimeGlassEdgeOverlayView()
    private var nativeGlass: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        fallbackVibrancy.material = .popover
        fallbackVibrancy.blendingMode = .behindWindow
        fallbackVibrancy.state = .active
        fallbackVibrancy.isHidden = true
        fallbackVibrancy.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fallbackVibrancy)

        glassEdgeOverlay.isHidden = true
        glassEdgeOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEdgeOverlay)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentHost)

        NSLayoutConstraint.activate([
            fallbackVibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
            fallbackVibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
            fallbackVibrancy.topAnchor.constraint(equalTo: topAnchor),
            fallbackVibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEdgeOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEdgeOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassEdgeOverlay.topAnchor.constraint(equalTo: topAnchor),
            glassEdgeOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.isHidden = true
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            nativeGlass = glass
        }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyStyle(cornerRadius: CGFloat,
                    backgroundColor: NSColor,
                    borderColor: NSColor,
                    borderWidth: CGFloat = 1,
                    usesLiquidGlass: Bool,
                    interactiveGlass: Bool = false) {
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = usesLiquidGlass ? 0 : borderWidth
        layer?.borderColor = usesLiquidGlass ? NSColor.clear.cgColor : borderColor.cgColor
        layer?.masksToBounds = !usesLiquidGlass
        glassEdgeOverlay.cornerRadius = cornerRadius
        glassEdgeOverlay.isHidden = !usesLiquidGlass

        if usesLiquidGlass {
            layer?.backgroundColor = RimeGlassPalette.panelFill.cgColor
            if #available(macOS 26.0, *),
               let glass = nativeGlass as? NSGlassEffectView {
                if glass.contentView !== contentHost {
                    glass.contentView = contentHost
                }
                glass.style = .regular
                glass.cornerRadius = cornerRadius
                glass.tintColor = RimeGlassPalette.panelTint
                Self.setInteractiveEffect(interactiveGlass, on: glass)
                glass.isHidden = false
                fallbackVibrancy.isHidden = true
            } else {
                if contentHost.superview !== self {
                    addSubview(contentHost, positioned: .above, relativeTo: fallbackVibrancy)
                }
                fallbackVibrancy.isHidden = false
            }
            return
        }

        if #available(macOS 26.0, *),
           let glass = nativeGlass as? NSGlassEffectView {
            Self.setInteractiveEffect(false, on: glass)
            if glass.contentView === contentHost {
                glass.contentView = nil
            }
            glass.isHidden = true
        }
        fallbackVibrancy.isHidden = true
        if contentHost.superview !== self {
            addSubview(contentHost, positioned: .above, relativeTo: fallbackVibrancy)
        }
        layer?.backgroundColor = backgroundColor.cgColor
    }

    /// macOS 27 adds this public AppKit property. Resolve the setter at runtime
    /// so the macOS 26 SDK build remains deployable to older systems too.
    static func setInteractiveEffect(_ enabled: Bool, on view: NSView) {
        let setter = NSSelectorFromString("setEffectIsInteractive:")
        guard view.responds(to: setter) else { return }
        view.setValue(NSNumber(value: enabled), forKey: "effectIsInteractive")
    }
}

/// Adds the fine highlight and inner edge visible on RIMES's MailGlass panels.
private final class RimeGlassEdgeOverlayView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth = RimeGlassPalette.edgeLineWidth
        guard bounds.width > lineWidth * 2,
              bounds.height > lineWidth * 2 else { return }

        let outerRect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let innerInset = lineWidth + 0.8
        let innerRect = bounds.insetBy(dx: innerInset, dy: innerInset)
        let outer = NSBezierPath(
            roundedRect: outerRect,
            xRadius: max(0, cornerRadius - lineWidth / 2),
            yRadius: max(0, cornerRadius - lineWidth / 2)
        )
        let inner = NSBezierPath(
            roundedRect: innerRect,
            xRadius: max(0, cornerRadius - innerInset),
            yRadius: max(0, cornerRadius - innerInset)
        )
        let edgeBand = NSBezierPath()
        edgeBand.windingRule = .evenOdd
        edgeBand.append(outer)
        edgeBand.append(inner)

        NSGraphicsContext.saveGraphicsState()
        edgeBand.addClip()
        NSGradient(colors: [
            .white.withAlphaComponent(RimeGlassPalette.edgeHighlightOpacity),
            .white.withAlphaComponent(0.08),
            .black.withAlphaComponent(RimeGlassPalette.edgeShadowOpacity),
            .white.withAlphaComponent(0.16),
        ])?.draw(in: bounds, angle: -45)
        NSGraphicsContext.restoreGraphicsState()

        inner.lineWidth = 0.8
        NSColor.white.withAlphaComponent(RimeGlassPalette.edgeGlowOpacity).setStroke()
        inner.stroke()
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
