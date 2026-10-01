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

    @Test("Caption ink on raised cards clears AA; inkTertiary is for canvas and surface only", arguments: [
        ("ink", Palette.pure), ("inkSoft", Palette.cloud), ("inkSecondary", Palette.ash),
    ])
    func raisedInkContrast(name: String, ink: RGB) {
        for (bgName, bg) in Self.raisedBackgrounds {
            let ratio = ink.contrast(with: bg)
            #expect(ratio >= 4.5, "\(name) on \(bgName) is \(ratio):1")
        }
        #expect(Palette.fog.contrast(with: Palette.graphite) < 4.5) // why raised cards don't use inkTertiary
    }

    @Test("White labels clear AA on the caution fill (swipe actions)")
    func cautionFill() {
        #expect(Palette.pure.contrast(with: Palette.deepOrchid) >= 4.5)
        #expect(Palette.pure.contrast(with: Palette.orchidBloom) < 3) // why the swipe doesn't use caution itself
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
