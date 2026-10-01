import SwiftUI

/// An sRGB color value that can be reasoned about (luminance, contrast) outside SwiftUI.
/// Tokens are defined as `RGB` first so tests can enforce contrast rules.
public struct RGB: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// This color laid over `background` at `opacity` — what the eye sees for a translucent fill,
    /// so contrast can be checked against washes like `tint.opacity(0.14)`.
    public func composited(over background: RGB, opacity: Double) -> RGB {
        RGB(red: red * opacity + background.red * (1 - opacity),
            green: green * opacity + background.green * (1 - opacity),
            blue: blue * opacity + background.blue * (1 - opacity))
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Raw palette, modeled on Origin's "midnight gallery": a near-black room, white type,
/// cyan for data, violet family for emphasis and category panels.
/// Use semantic tokens (`Color.ds`) in views; reach for `Palette` only when defining tokens.
public enum Palette {
    // Neutrals — depth is built from shade breaks, not bright borders.
    public static let void = RGB(hex: 0x000000)
    public static let abyss = RGB(hex: 0x090A0B)
    public static let obsidian = RGB(hex: 0x0F1011)
    public static let carbon = RGB(hex: 0x161718)
    public static let graphite = RGB(hex: 0x1F2022)
    public static let steel = RGB(hex: 0x3F4041)
    /// Origin's "Fog" (#6A6B6B) fails WCAG AA for small text on the canvas (3.5:1).
    /// Lifted to #808182 so tertiary text clears 4.5:1 on canvas and surface.
    public static let fog = RGB(hex: 0x808182)
    public static let ash = RGB(hex: 0x9F9FA0)
    public static let silver = RGB(hex: 0xCACACA)
    public static let cloud = RGB(hex: 0xF5F5F7)
    public static let pure = RGB(hex: 0xFFFFFF)

    // Chromatic accents.
    public static let cyanSignal = RGB(hex: 0x00B3DD)
    public static let irisGleam = RGB(hex: 0x847DFF)
    /// Saturated violet-lilac (was Origin's pale iris #D1C9FF, which read dusty).
    public static let lilac = RGB(hex: 0xD08FFF)
    public static let deepIris = RGB(hex: 0x4B49AA)
    /// Brightened from Origin's #DD90D8.
    public static let orchidBloom = RGB(hex: 0xEF72E3)
    /// Orchid dark enough to carry white labels (iOS draws swipe-action labels white): 5.6:1.
    public static let deepOrchid = RGB(hex: 0xB0309F)
    /// Clear azure (was periwinkle #90B8F0).
    public static let azure = RGB(hex: 0x5AA0FF)
    /// The first warm tone — replaces a neutral silver tile, since a gray can't be made un-dusty.
    public static let amber = RGB(hex: 0xFFB42E)

    // Category tones added so twelve categories can each own a colour. All saturated, none a
    // pure red or green (those would read as "bad" and "good" money), all AA with black ink.
    public static let coral = RGB(hex: 0xFF7A59)
    public static let rose = RGB(hex: 0xFF5C8A)
    public static let teal = RGB(hex: 0x14C7B4)
    public static let lime = RGB(hex: 0xB8E62E)
    public static let violet = RGB(hex: 0x9B5CFF)
}

/// Semantic color tokens. Views use these, never raw hex.
public struct DSColors: Sendable {
    // Surfaces, back to front.
    public let canvasDeep = Palette.abyss.color
    public let canvas = Palette.obsidian.color
    public let surface = Palette.carbon.color
    public let surfaceRaised = Palette.graphite.color
    public let surfacePressed = Palette.steel.color
    public let hairline = Color.white.opacity(0.08)
    public let hairlineStrong = Color.white.opacity(0.16)

    // Ink.
    public let ink = Palette.pure.color
    public let inkSoft = Palette.cloud.color
    public let inkSecondary = Palette.ash.color
    public let inkTertiary = Palette.fog.color
    public let inkInverse = Palette.void.color

    // Accents.
    public let accent = Palette.cyanSignal.color
    public let iris = Palette.irisGleam.color
    public let lilac = Palette.lilac.color
    public let irisDeep = Palette.deepIris.color
    public let orchid = Palette.orchidBloom.color
    public let azure = Palette.azure.color
    public let amber = Palette.amber.color

    // Money signals. Origin avoids bright green/red; so do we.
    /// Money coming in.
    public let inflow = Palette.cyanSignal.color
    /// Over target, needs attention.
    public let caution = Palette.orchidBloom.color
    /// Caution as a fill under white labels (a Delete swipe action).
    public let cautionFill = Palette.deepOrchid.color
}

extension Color {
    public static let ds = DSColors()
}

/// Chromatic panel tones, used for category tiles, row glyphs, and chart series.
/// Each tone carries its own on-tile ink so text contrast is guaranteed (see tests).
///
/// The raw value is the tone's token name. It is what a category stores as its colour
/// (never a hex value), so renaming a case is a wire change.
public enum DSTone: String, CaseIterable, Sendable {
    // Append new tones at the end: `allCases` order is the token list other layers mirror.
    case iris, lilac, orchid, azure, cyan, irisDeep, amber
    case coral, rose, teal, lime, violet

    /// Resolves a stored token name, forgiving case and stray whitespace. Unknown or missing
    /// tokens return nil so the caller can fall back to its own default.
    public init?(token: String?) {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !token.isEmpty else { return nil }
        guard let tone = Self.allCases.first(where: { $0.rawValue.lowercased() == token }) else { return nil }
        self = tone
    }

    /// The token name to store, e.g. `BudgetCategory.color`.
    public var token: String { rawValue }

    /// Every tone in picker order: around the colour wheel, so neighbours read as a gradient.
    public static let swatches: [DSTone] = [
        .violet, .iris, .irisDeep, .azure, .cyan, .teal,
        .lime, .amber, .coral, .rose, .orchid, .lilac,
    ]

    /// What VoiceOver calls the tone in a picker.
    public var displayName: String {
        switch self {
        case .irisDeep: "Deep iris"
        default: rawValue.capitalized
        }
    }

    public var rgb: RGB {
        switch self {
        case .iris: Palette.irisGleam
        case .lilac: Palette.lilac
        case .orchid: Palette.orchidBloom
        case .azure: Palette.azure
        case .cyan: Palette.cyanSignal
        case .irisDeep: Palette.deepIris
        case .amber: Palette.amber
        case .coral: Palette.coral
        case .rose: Palette.rose
        case .teal: Palette.teal
        case .lime: Palette.lime
        case .violet: Palette.violet
        }
    }

    public var onFillRGB: RGB { self == .irisDeep ? Palette.pure : Palette.void }

    /// The tone as foreground on the dark canvas (irisDeep is too dark for that, so it lifts to iris).
    public var onCanvasRGB: RGB { self == .irisDeep ? Palette.irisGleam : rgb }

    public var fill: Color { rgb.color }
    public var onFill: Color { onFillRGB.color }
    /// Low-intensity wash for glyph backgrounds on dark surfaces.
    public var wash: Color { rgb.color.opacity(0.16) }
    /// Tone that reads as foreground on the dark canvas.
    public var onCanvas: Color { onCanvasRGB.color }
}
