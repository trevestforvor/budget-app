import Foundation
import Testing
@testable import DesignSystem

/// The palette is dark and quiet; these tests keep it legible.
@Suite("Design tokens")
struct ContrastTests {
    static let backgrounds: [(String, RGB)] = [("canvas", Palette.obsidian), ("surface", Palette.carbon)]

    @Test("Body ink clears WCAG AA (4.5:1) on canvas and surface", arguments: [
        ("ink", Palette.pure), ("inkSoft", Palette.cloud), ("inkSecondary", Palette.ash), ("inkTertiary", Palette.fog),
        ("accent", Palette.cyanSignal), ("iris", Palette.irisGleam), ("orchid", Palette.orchidBloom), ("azure", Palette.azure),
    ])
    func inkContrast(name: String, ink: RGB) {
        for (bgName, bg) in Self.backgrounds {
            let ratio = ink.contrast(with: bg)
            #expect(ratio >= 4.5, "\(name) on \(bgName) is \(ratio):1")
        }
    }

    @Test("Text on every chromatic tile clears AA", arguments: DSTone.allCases)
    func tileContrast(tone: DSTone) {
        let ratio = tone.onFillRGB.contrast(with: tone.rgb)
        #expect(ratio >= 4.5, "\(tone) tile text is \(ratio):1")
    }

    @Test("Every tone reads as foreground on canvas and surface", arguments: DSTone.allCases)
    func onCanvasContrast(tone: DSTone) {
        for (bgName, bg) in Self.backgrounds {
            let ratio = tone.onCanvasRGB.contrast(with: bg)
            #expect(ratio >= 4.5, "\(tone) on \(bgName) is \(ratio):1")
        }
    }

    @Test("The five added category tones are the agreed values and take black ink")
    func addedTones() {
        let expected: [(DSTone, UInt32)] = [(.coral, 0xFF7A59), (.rose, 0xFF5C8A), (.teal, 0x14C7B4), (.lime, 0xB8E62E), (.violet, 0x9B5CFF)]
        for (tone, hex) in expected {
            #expect(tone.rgb == RGB(hex: hex), "\(tone) drifted from #\(String(hex, radix: 16))")
            #expect(tone.onFillRGB == Palette.void)
        }
    }

    @Test("White glyphs on amber fail even 3:1 — why icon tiles use each tone's own ink")
    func whiteOnAmberFails() {
        #expect(Palette.pure.contrast(with: Palette.amber) < 3)
        #expect(DSTone.amber.onFillRGB.contrast(with: DSTone.amber.rgb) >= 4.5)
    }

    static let raisedBackgrounds: [(String, RGB)] = backgrounds + [("surfaceRaised", Palette.graphite)]

    /// Every layer of the room, back to front, including the lit top stops of the card fills.
    static let ladder: [(String, RGB)] = [
        ("canvasDeep", Palette.abyss), ("canvas", Palette.obsidian), ("surface", Palette.carbon), ("surfaceLit", Palette.carbonLit),
        ("surfaceRaised", Palette.graphite), ("raisedLit", Palette.graphiteLit), ("surfaceOverlay", Palette.basalt), ("surfacePressed", Palette.slate),
    ]

    @Test("Caption ink on raised cards clears AA", arguments: [
        ("ink", Palette.pure), ("inkSoft", Palette.cloud), ("inkSecondary", Palette.ash), ("inkTertiary", Palette.fog),
    ])
    func raisedInkContrast(name: String, ink: RGB) {
        for (bgName, bg) in Self.raisedBackgrounds {
            let ratio = ink.contrast(with: bg)
            #expect(ratio >= 4.5, "\(name) on \(bgName) is \(ratio):1")
        }
    }

    @Test("inkTertiary clears AA up to the raised card, and not on the overlay — why toasts and menus use inkSecondary")
    func tertiaryInkReach() {
        for name in ["canvasDeep", "canvas", "surface", "surfaceLit", "surfaceRaised", "raisedLit"] {
            let bg = Self.ladder.first { $0.0 == name }!.1
            let ratio = Palette.fog.contrast(with: bg)
            #expect(ratio >= 4.5, "inkTertiary on \(name) is \(ratio):1")
        }
        #expect(Palette.fog.contrast(with: Palette.basalt) < 4.5)
        #expect(Palette.fog.contrast(with: Palette.slate) < 4.5)
    }

    @Test("ink, inkSoft and inkSecondary clear AA on every layer of the ladder", arguments: [
        ("ink", Palette.pure), ("inkSoft", Palette.cloud), ("inkSecondary", Palette.ash),
    ])
    func ladderInkContrast(name: String, ink: RGB) {
        for (bgName, bg) in Self.ladder {
            let ratio = ink.contrast(with: bg)
            #expect(ratio >= 4.5, "\(name) on \(bgName) is \(ratio):1")
        }
    }

    @Test("The opaque field border clears 3:1 (WCAG 1.4.11) everywhere a field may sit, and not on the overlay")
    func fieldBorder() {
        for (bgName, bg) in [("canvasDeep", Palette.abyss), ("canvas", Palette.obsidian), ("surface", Palette.carbon), ("surfaceRaised", Palette.graphite)] {
            let ratio = Palette.rim.contrast(with: bg)
            #expect(ratio >= 3, "fieldBorder on \(bgName) is \(ratio):1")
        }
        #expect(Palette.rim.contrast(with: Palette.basalt) < 3) // why a field never sits on the overlay
    }

    @Test("Inverse ink clears AA on every fill it sits on", arguments: [
        ("white", Palette.pure), ("pearl", Palette.pearl), ("pearlPressed", Palette.pearlPressed),
        ("cyan", Palette.cyanSignal), ("iris", Palette.irisGleam),
    ])
    func inverseInk(name: String, fill: RGB) {
        let ratio = Palette.obsidian.contrast(with: fill)
        #expect(ratio >= 4.5, "inkInverse on \(name) is \(ratio):1")
    }

    @Test("Every tone's foreground clears AA on its own tag wash, and bare on canvas, surface and raised", arguments: DSTone.allCases)
    func toneOnWash(tone: DSTone) {
        for (bgName, bg) in Self.backgrounds {
            let wash = tone.rgb.composited(over: bg, opacity: DSWash.tag.opacity)
            let ratio = tone.onCanvasRGB.contrast(with: wash)
            #expect(ratio >= 4.5, "\(tone) on its wash over \(bgName) is \(ratio):1")
        }
        for (bgName, bg) in Self.raisedBackgrounds {
            let ratio = tone.onCanvasRGB.contrast(with: bg)
            #expect(ratio >= 4.5, "\(tone) on \(bgName) is \(ratio):1")
        }
    }

    @Test("Violet itself misses AA on a raised card — why its foreground lifts to violetLit")
    func violetLifts() {
        #expect(Palette.violet.contrast(with: Palette.graphite) < 4.5)
        #expect(DSTone.violet.onCanvasRGB == Palette.violetLit)
    }

    @Test("Tile ink clears AA through the gloss, at its brightest", arguments: DSTone.allCases)
    func tileGloss(tone: DSTone) {
        let glossed = Palette.pure.composited(over: tone.rgb, opacity: tone.gloss)
        let ratio = tone.onFillRGB.contrast(with: glossed)
        #expect(ratio >= 4.5, "\(tone) tile ink under the gloss is \(ratio):1")
    }

    @Test("irisDeep's gloss stops at 10%: at the standard 14% its white ink would fall toward the line")
    func irisDeepGlossCap() {
        #expect(DSTone.irisDeep.gloss == 0.10)
        let capped = Palette.pure.composited(over: Palette.deepIris, opacity: 0.10)
        #expect(Palette.pure.contrast(with: capped) >= 4.5)
    }

    @Test("White labels clear AA on the caution fill, at rest and pressed")
    func cautionFill() {
        #expect(Palette.pure.contrast(with: Palette.deepOrchid) >= 4.5)
        #expect(Palette.pure.contrast(with: Palette.deepOrchidPressed) >= 4.5)
        #expect(Palette.pure.contrast(with: Palette.orchidBloom) < 3) // why the swipe doesn't use caution itself
    }

    @Test("Caution reads on a field's well and on a card; secondary ink reads on the caution wash")
    func cautionText() {
        #expect(Palette.orchidBloom.contrast(with: Palette.abyss) >= 4.5)
        #expect(Palette.orchidBloom.contrast(with: Palette.carbon) >= 4.5)
        let wash = Palette.orchidBloom.composited(over: Palette.carbon, opacity: 0.18)
        #expect(Palette.ash.contrast(with: wash) >= 4.5)
        #expect(Palette.fog.contrast(with: wash) < 4.5) // why text on the caution wash is inkSecondary or brighter
    }

    @Test("The tinted button's cyan label clears AA on its own wash, on cards and raised cards")
    func tintedButton() {
        for (bgName, bg) in [("surface", Palette.carbon), ("surfaceRaised", Palette.graphite)] {
            let wash = Palette.cyanSignal.composited(over: bg, opacity: 0.14)
            let ratio = Palette.cyanSignal.contrast(with: wash)
            #expect(ratio >= 4.5, "tinted label over \(bgName) is \(ratio):1")
        }
    }

    @Test("Secondary ink clears AA under the screen blooms")
    func screenBlooms() {
        let data = Palette.cyanSignal.composited(over: Palette.obsidian, opacity: DSScreenBloom.data.intensity)
        let ai = Palette.irisGleam.composited(over: Palette.obsidian, opacity: DSScreenBloom.ai.intensity)
        #expect(Palette.ash.contrast(with: data) >= 4.5)
        #expect(Palette.ash.contrast(with: ai) >= 4.5)
    }

    @Test("Week strip: white ink clears AA on the strongest fill, on every surface it sits on")
    func weekStripStrongestFill() {
        for (bgName, bg) in Self.raisedBackgrounds {
            let fill = Palette.cyanSignal.composited(over: bg, opacity: DSWeekStrip.maxFillOpacity)
            for (inkName, ink) in [("ink", Palette.pure), ("inkSoft", Palette.cloud)] {
                let ratio = ink.contrast(with: fill)
                #expect(ratio >= 4.5, "\(inkName) on the strongest fill over \(bgName) is \(ratio):1")
            }
        }
        // A day with nothing spent is `surfaceRaised` with its amount in `inkSecondary`.
        #expect(Palette.ash.contrast(with: Palette.graphite) >= 4.5)
    }

    @Test("Week strip: black ink on a half-strength fill would fail — why the strip never switches ink")
    func weekStripBlackInkFails() {
        let half = Palette.cyanSignal.composited(over: Palette.carbon, opacity: 0.5)
        #expect(Palette.void.contrast(with: half) < 4.5)
        let strongest = Palette.cyanSignal.composited(over: Palette.carbon, opacity: DSWeekStrip.maxFillOpacity)
        #expect(Palette.void.contrast(with: strongest) < 4.5)
    }

    @Test("Attention pill text clears AA on its own wash", arguments: [
        ("caution", Palette.orchidBloom), ("amber", Palette.amber), ("accent", Palette.cyanSignal),
    ])
    func attentionPillContrast(name: String, tint: RGB) {
        for (bgName, bg) in Self.backgrounds {
            let ratio = tint.contrast(with: tint.composited(over: bg, opacity: 0.14))
            #expect(ratio >= 4.5, "\(name) pill on \(bgName) is \(ratio):1")
        }
    }

    @Test("Half-opacity rows would fail AA — why muted rows change ink instead of fading")
    func fadedRowFails() {
        let fadedSubtitle = Palette.ash.composited(over: Palette.carbon, opacity: 0.5)
        #expect(fadedSubtitle.contrast(with: Palette.carbon) < 4.5)
        #expect(Palette.ash.contrast(with: Palette.carbon) >= 4.5)
        #expect(Palette.fog.contrast(with: Palette.carbon) >= 4.5)
    }

    @Test("Origin's original Fog would fail AA — the documented reason tertiary ink was lifted")
    func originalFogFails() {
        #expect(RGB(hex: 0x6A6B6B).contrast(with: Palette.obsidian) < 4.5)
    }

    @Test("Amount formatting keeps sign conventions")
    func amountFormatting() {
        let us = Locale(identifier: "en_US")
        #expect(DSAmountFormat.string(-12.5, currencyCode: "USD", locale: us) == "−$12.50")
        #expect(DSAmountFormat.string(3850, currencyCode: "USD", sign: .inflowPlus, locale: us) == "+$3,850.00")
        #expect(DSAmountFormat.string(-84.12, currencyCode: "USD", sign: .inflowPlus, locale: us) == "$84.12")
        let parts = DSAmountFormat.split(24_812.46, currencyCode: "USD", locale: us)
        #expect(parts.whole == "$24,812")
        #expect(parts.fraction == ".46")
    }
}
