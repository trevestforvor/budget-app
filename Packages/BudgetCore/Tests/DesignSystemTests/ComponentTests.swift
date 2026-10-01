import Foundation
import Testing
@testable import DesignSystem
#if canImport(AppKit)
import AppKit
#endif

/// Tones are stored by token name, so the list and its lookups are part of the wire contract.
@Suite("Tone tokens")
struct ToneTokenTests {
    @Test("Token order: the original seven, then the five added, never reshuffled")
    func tokenOrder() {
        #expect(DSTone.allCases.map(\.token) == ["iris", "lilac", "orchid", "azure", "cyan", "irisDeep", "amber",
                                                 "coral", "rose", "teal", "lime", "violet"])
    }

    @Test("Every token resolves back to its tone", arguments: DSTone.allCases)
    func roundTrip(tone: DSTone) {
        #expect(DSTone(token: tone.token) == tone)
    }

    @Test("Lookup forgives case and whitespace, and returns nil for anything unknown")
    func lenientLookup() {
        #expect(DSTone(token: "IrisDeep") == .irisDeep)
        #expect(DSTone(token: " teal\n") == .teal)
        #expect(DSTone(token: nil) == nil)
        #expect(DSTone(token: "") == nil)
        #expect(DSTone(token: "#FF7A59") == nil)
        #expect(DSTone(token: "hotpink") == nil)
    }

    @Test("The picker shows every tone exactly once")
    func swatchesCoverAllTones() {
        #expect(DSTone.swatches.count == DSTone.allCases.count)
        #expect(Set(DSTone.swatches) == Set(DSTone.allCases))
    }

    @Test("VoiceOver names are words, and distinct")
    func displayNames() {
        let names = DSTone.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(DSTone.irisDeep.displayName == "Deep iris")
        #expect(DSTone.coral.displayName == "Coral")
    }
}

@Suite("Components")
struct ComponentLogicTests {
    // MARK: Over target

    @Test("The progress bar rescales past the target so the notch marks it")
    func progressTargetPosition() {
        #expect(DSProgressBar.targetPosition(for: 0.5) == 1)
        #expect(DSProgressBar.targetPosition(for: 1) == 1)
        #expect(DSProgressBar.targetPosition(for: 1.25) == 0.8)
        #expect(DSProgressBar.targetPosition(for: 2) == 0.5)
        #expect(!DSProgressBar.isOver(1))
        #expect(DSProgressBar.isOver(1.01))
    }

    @Test("The filled share is clamped, and nonsense fractions don't draw nonsense")
    func progressFilled() {
        #expect(DSProgressBar.filled(for: -0.2) == 0)
        #expect(DSProgressBar.filled(for: 0.4) == 0.4)
        #expect(DSProgressBar.filled(for: 1.5) == 1)
        #expect(DSProgressBar.filled(for: .nan) == 0)
        #expect(DSProgressBar.filled(for: .infinity) == 1)
    }

    @Test("A month bar is over only against a real target")
    func monthBarOver() {
        #expect(!DSMonthBars.isOver(500, target: nil))
        #expect(!DSMonthBars.isOver(500, target: 0))
        #expect(!DSMonthBars.isOver(450, target: 450))
        #expect(DSMonthBars.isOver(451, target: 450))
    }

    @Test("A tap anywhere in a month picks that month's bar, else the nearest")
    func monthBarNearest() throws {
        let calendar = Self.calendar
        let bars = (1...3).map { DSMonthBar(month: Self.date(2026, $0, 1), value: Double($0)) }
        #expect(DSMonthBars.bar(nearest: Self.date(2026, 2, 27), in: bars, calendar: calendar)?.value == 2)
        #expect(DSMonthBars.bar(nearest: Self.date(2026, 7, 4), in: bars, calendar: calendar)?.value == 3)
        #expect(DSMonthBars.bar(nearest: Self.date(2026, 1, 1), in: [], calendar: calendar) == nil)
    }

    @Test("Month axis marks sit mid-month, under their bars, whatever day the data carries")
    func monthAxisMidpoint() {
        let calendar = Self.calendar
        let mid = monthMidpoint(Self.date(2026, 9, 26), calendar: calendar)
        #expect(calendar.isDate(mid, equalTo: Self.date(2026, 9, 1), toGranularity: .month))
        #expect(calendar.component(.day, from: mid) == 16, "September is 30 days, so its midpoint is the 16th at 00:00")
        #expect(monthMidpoint(Self.date(2026, 9, 1), calendar: calendar) == mid)
    }

    // MARK: Rows

    @Test("VoiceOver hears why a row is quiet", arguments: [
        (DSEmphasis.normal, false, false, false, [String]()),
        (.muted, false, false, false, ["not counted"]),
        (.normal, true, false, false, ["hidden"]),
        (.muted, true, false, false, ["hidden"]),
        (.normal, false, true, true, ["needs review", "pending"]),
        (.muted, true, true, true, ["hidden", "needs review", "pending"]),
    ])
    func rowStatuses(emphasis: DSEmphasis, isHidden: Bool, needsReview: Bool, isPending: Bool, expected: [String]) {
        #expect(DSTransactionRow.accessibilityStatuses(emphasis: emphasis, isHidden: isHidden, needsReview: needsReview, isPending: isPending) == expected)
    }

    // MARK: Toast

    @Test("An undo toast carries its action; a plain one has no button")
    @MainActor
    func toastMessage() {
        var undone = false
        let undo = DSToastMessage.undo("Filed 12 as Transfer") { undone = true }
        #expect(undo.actionTitle == "Undo")
        undo.action?()
        #expect(undone)

        let plain = DSToastMessage("Rule saved", actionTitle: "Undo")
        #expect(plain.actionTitle == nil, "a title with nothing to do would be a dead button")
        #expect(plain != DSToastMessage("Rule saved"), "each toast is its own, even with the same words")
        #expect(plain == plain)
    }

    @Test("Toasts stay up longer under VoiceOver, so Undo can be reached")
    func toastDuration() {
        let toast = DSToastMessage("Filed", duration: .seconds(4))
        #expect(toast.visibleDuration(voiceOver: false) == .seconds(4))
        #expect(toast.visibleDuration(voiceOver: true) == .seconds(10))
        #expect(DSToastMessage("Filed", duration: .seconds(6)).visibleDuration(voiceOver: true) == .seconds(15))
        #expect(toast.visibleDuration(voiceOver: false, switchControl: true) == .seconds(10))
    }

    // MARK: Month switcher

    @Test("The month switcher steps by whole months and stops at its bounds")
    func monthSteps() {
        let calendar = Self.calendar
        let september = Self.date(2026, 9, 18)
        let latest = Self.date(2026, 9, 26)
        #expect(DSMonthSwitcher.step(september, by: 1, earliest: nil, latest: latest, calendar: calendar) == nil)
        #expect(DSMonthSwitcher.step(september, by: -1, earliest: nil, latest: latest, calendar: calendar) == Self.date(2026, 8, 1))
        #expect(DSMonthSwitcher.step(september, by: 0, earliest: nil, latest: latest, calendar: calendar) == Self.date(2026, 9, 1))
        #expect(DSMonthSwitcher.step(september, by: -13, earliest: nil, latest: latest, calendar: calendar) == Self.date(2025, 8, 1))
        let earliest = Self.date(2026, 8, 15)
        #expect(DSMonthSwitcher.step(september, by: -1, earliest: earliest, latest: latest, calendar: calendar) == Self.date(2026, 8, 1))
        #expect(DSMonthSwitcher.step(september, by: -2, earliest: earliest, latest: latest, calendar: calendar) == nil)
    }

    // MARK: Week strip

    @Test("Week strip fills scale with the heaviest day and leave empty days unfilled")
    func weekFill() throws {
        #expect(DSWeekStrip.fillOpacity(for: 0, heaviest: 310) == nil)
        #expect(DSWeekStrip.fillOpacity(for: 20, heaviest: 0) == nil)
        #expect(DSWeekStrip.fillOpacity(for: 310, heaviest: 310) == DSWeekStrip.maxFillOpacity)
        #expect(DSWeekStrip.fillOpacity(for: -310, heaviest: 310) == DSWeekStrip.maxFillOpacity, "a refund-heavy day still reads by size")
        let half = try #require(DSWeekStrip.fillOpacity(for: 155, heaviest: 310))
        #expect(abs(half - (DSWeekStrip.minFillOpacity + DSWeekStrip.maxFillOpacity) / 2) < 0.0001)
        let tiny = try #require(DSWeekStrip.fillOpacity(for: 1, heaviest: 310))
        #expect(tiny > DSWeekStrip.minFillOpacity && tiny < half)
    }

    @Test("Week strip amounts stay short enough for seven cells")
    func weekLabels() {
        let us = Locale(identifier: "en_US")
        #expect(DSWeekStrip.amountLabel(48.4, currencyCode: "USD", locale: us) == "$48")
        #expect(DSWeekStrip.amountLabel(0, currencyCode: "USD", locale: us) == "$0")
        #expect(DSWeekStrip.amountLabel(-126, currencyCode: "USD", locale: us) == "$126")
        #expect(DSWeekStrip.amountLabel(1_234, currencyCode: "USD", locale: us) == "$1.2K")
    }

    // MARK: Symbols

    @Test("The category symbol set is 48 distinct symbols that include every default category's")
    func symbolCatalog() {
        let names = DSSymbol.budgetCategories.map(\.systemName)
        #expect(names.count == 48)
        #expect(Set(names).count == names.count)
        let defaults = ["cart", "fork.knife", "car", "house", "bolt", "repeat", "bag", "ticket", "heart", "airplane", "percent",
                        "arrow.down.circle", "arrow.left.arrow.right", "tag"]
        for name in defaults { #expect(names.contains(name), "\(name) is a default category symbol") }
        #expect(Set(DSSymbol.budgetCategories.map(\.label)).count == names.count, "VoiceOver labels are distinct")
    }

    #if canImport(AppKit)
    @Test("Every catalog symbol exists in SF Symbols", arguments: DSSymbol.budgetCategories)
    func symbolExists(symbol: DSSymbol) {
        #expect(NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil) != nil, "\(symbol.systemName) isn't an SF Symbol")
    }
    #endif

    @Test("Symbol search matches labels, keywords and names, ignoring case and accents")
    func symbolSearch() {
        #expect(DSSymbol.search("").count == DSSymbol.budgetCategories.count)
        #expect(DSSymbol.search("rent").map(\.systemName) == ["house"])
        #expect(DSSymbol.search("CAFÉ").map(\.systemName) == ["cup.and.saucer"])
        #expect(DSSymbol.search("fork").map(\.systemName) == ["fork.knife"])
        #expect(DSSymbol.search("zzz").isEmpty)
    }

    // MARK: Helpers

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
