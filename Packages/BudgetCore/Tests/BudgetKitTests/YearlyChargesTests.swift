import Foundation
import Testing
@testable import BudgetKit

/// Charges spread over the year: found (a yearly series, a description that says annual) or marked by the person, they
/// count a twelfth a month in their own bucket instead of landing whole in their month and in the usual month after.
@Suite("Yearly charges")
struct YearlyChargesTests {
    /// Now is 25 Sep 2026. The ledger reaches back to 21 Aug 2025, so the twelve months before this one are covered.
    static func rows() -> [LedgerTransaction] {
        var wool = Rows.row("wool", "card", 10, -600, "WOOL AND COMPANY", "shopping")
        wool.isYearly = true
        var notYearly = Rows.row("plan", "card", 20, -40, "ANNUAL PLAN REVIEW", "fees")
        notYearly.isYearly = false
        return [
            Rows.row("first", "card", 400, -10, "SAFEWAY", "groceries"),
            // A year apart: the recurring search calls it yearly.
            Rows.row("origin-2025", "card", 390, -99, "ORIGIN FINANCIAL", "subscriptions"),
            Rows.row("origin-2026", "card", 25, -99, "ORIGIN FINANCIAL", "subscriptions"),
            // Says so.
            Rows.row("fee", "card", 24, -795, "ANNUAL MEMBERSHIP FEE", "fees"),
            // Monthly.
            Rows.row("spotify-6", "card", 102, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-7", "card", 72, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-8", "card", 41, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-9", "card", 10, -12, "SPOTIFY USA", "subscriptions"),
            wool, notYearly,
            Rows.row("trip", "card", 150, -1200, "UNITED AIRLINES", "travel"),
            Rows.row("dinner", "card", 5, -50, "HARVEST TABLE", "dining"),
        ]
    }

    @Test("Found in a yearly series, said in the description, or marked by the person; the person's no wins")
    func whichAreYearly() {
        let ledger = Rows.ledger(Self.rows())
        #expect(ledger.yearlyIDs == ["origin-2025", "origin-2026", "fee", "wool"])
    }

    @Test("\"Annual\" and \"yearly\" say it; semi-annual, bi-annual and plant nurseries don't")
    func saysAnnual() {
        func says(_ text: String) -> Bool { Ledger.saysAnnual(Rows.row("x", "card", 1, -10, text, "fees")) }
        #expect(says("ANNUAL MEMBERSHIP FEE"))
        #expect(says("Yearly plan"))
        #expect(says("NYTIMES BILLED ANNUALLY"))
        #expect(!says("SEMI-ANNUAL PREMIUM"))
        #expect(!says("BI ANNUAL DUES"))
        #expect(!says("ANNUALS NURSERY"))
        #expect(!says("SPOTIFY USA"))
    }

    @Test("A charge spread over the year counts a twelfth a month in its own bucket, in the usual month and this one")
    func flexBudget() {
        let ledger = Rows.ledger(Self.rows())
        let c = ledger.capacity()
        // June to August: Spotify's $12, plus a twelfth of Origin's $99 (last year's covers June and July, this
        // year's August) — $20.25 a month of subscriptions. No bills; the trip was in April.
        #expect(c.subscriptions == Money(20.25) && c.bills == .zero && c.everyday == .zero)
        // This month's everyday: dinner, and a twelfth of the $600 marked yearly.
        #expect(ledger.flexBudget().flexSpent == Money(100))
    }

    @Test("The budget month lists spread charges at their twelfth, by category, in their own bucket")
    func budgetMonth() throws {
        let month = try Rows.ledger(Self.rows()).budgetMonth(nil)
        let groups = Dictionary(uniqueKeysWithValues: month.groups.map { ($0.group, $0) })
        // Bills: the $795 annual fee at $66.25, and the $40 fee the person said isn't yearly.
        #expect(groups[.bills]?.categories.map(\.id) == ["fees-yearly", "fees"])
        #expect(groups[.bills]?.spent == Money(106.25))
        // Subscriptions: Spotify, and Origin's twelfth.
        #expect(groups[.subscriptions]?.categories.map(\.id) == ["subscriptions", "subscriptions-yearly"])
        #expect(groups[.subscriptions]?.spent == Money(20.25))
        #expect(groups[.everyday]?.categories.map(\.id) == ["dining", "shopping-yearly"])
        #expect(month.groups.flatMap(\.categories).filter { $0.isYearly == true }.count == 3)
    }

    @Test("The month's pace leaves yearly charges out, and says so")
    func pace() throws {
        let pace = try #require(Rows.ledger(Self.rows()).monthPace())
        // This month: Spotify $12, the $40 fee, dinner $50. The $795 fee and the $600 marked yearly are left out.
        #expect(pace.soFar == Money(102))
        #expect(pace.leftOutYearly)
    }

    @Test("Marking a charge not yearly moves it back to its month; undo gives it back to Budget to decide")
    func edit() async throws {
        let api = Rows.api(Self.rows())
        #expect(try await api.transaction(id: "fee").countsAsYearly == true)
        #expect(try await api.transaction(id: "spotify-9").countsAsYearly == nil)

        let preview = try await api.preview(.editTransactions(EditTransactions(transactionIDs: ["dinner"], isYearly: true)))
        #expect(preview.title == "Spread 1 transaction over the year")
        #expect(preview.effects.first { $0.id == "yearly-month" }?.value == Money(4.16))

        let result = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["fee"], isYearly: false)))
        #expect(result.message == "Counted in the month charged.")
        #expect(try await api.transaction(id: "fee").countsAsYearly == nil)
        // The whole $795 is this month's bills now, with the $40 fee.
        #expect(try await api.budget(month: nil).groups.first { $0.group == .bills }?.spent == Money(835))

        _ = try await api.perform(try #require(result.undo))
        let restored = try await api.transaction(id: "fee")
        #expect(restored.isYearly == nil && restored.countsAsYearly == true)
    }

    @Test("A row stored before yearly charges existed decodes as Budget's to decide")
    func decodesOldRow() throws {
        let row = Rows.row("old", "card", 1, -10, "SAFEWAY", "groceries")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        json.removeValue(forKey: "isYearly")
        let decoded = try JSONDecoder().decode(LedgerTransaction.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.isYearly == nil && decoded.countsAsYearly == nil)
    }
}

/// Recurring charges the person corrects: a restaurant that only looks like a subscription, a first yearly charge
/// Budget can't know yet, a subscription that's really a bill.
@Suite("Recurring choices")
struct RecurringChoicesTests {
    static func rows() -> [LedgerTransaction] {
        [
            // Every three months or so: Budget calls it quarterly.
            Rows.row("brenda-1", "card", 200, -100.96, "BRENDAS MEAT", "dining"),
            Rows.row("brenda-2", "card", 110, -95.20, "BRENDAS MEAT", "dining"),
            Rows.row("brenda-3", "card", 20, -83.34, "BRENDAS MEAT", "dining"),
            // One charge so far.
            Rows.row("origin", "card", 12, -99, "ORIGIN FINANCIAL", "subscriptions"),
            Rows.row("spotify-7", "card", 72, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-8", "card", 41, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-9", "card", 10, -12, "SPOTIFY USA", "subscriptions"),
        ]
    }

    @Test("A restaurant taken off recurring leaves the list; undo puts it back")
    func notRecurring() async throws {
        let api = Rows.api(Self.rows())
        #expect(try await api.subscriptions().items.first { $0.merchant == "Brendas Meat" }?.cadence == .quarterly)
        let result = try await api.perform(.setRecurring(SetRecurring(merchant: "brendas meat", isRecurring: false)))
        #expect(result.message == "Took Brendas Meat off recurring.")
        #expect(try await api.subscriptions().items.contains { $0.merchant == "Brendas Meat" } == false)
        #expect(try await api.subscriptions().notRecurring == ["Brendas Meat"])
        _ = try await api.perform(try #require(result.undo))
        #expect(try await api.subscriptions().items.contains { $0.merchant == "Brendas Meat" })
    }

    @Test("A first yearly charge, marked by the person, is recurring from its one charge and set aside as yearly")
    func addYearly() async throws {
        let api = Rows.api(Self.rows())
        #expect(try await api.subscriptions().items.contains { $0.merchant == "Origin Financial" } == false)
        let preview = try await api.preview(.setRecurring(SetRecurring(merchant: "Origin Financial", isRecurring: true, cadence: .yearly)))
        #expect(preview.title == "Origin Financial repeats every year")
        _ = try await api.perform(.setRecurring(SetRecurring(merchant: "Origin Financial", isRecurring: true, cadence: .yearly)))
        let origin = try #require(try await api.subscriptions().items.first { $0.merchant == "Origin Financial" })
        #expect(origin.cadence == .yearly && origin.setByPerson == true && origin.charges == 1)
        #expect(try await api.transaction(id: "origin").countsAsYearly == true)
    }

    @Test("A subscription made a bill keeps its cadence; asking to recur with nothing to go on is refused")
    func kindAndRefusal() async throws {
        let api = Rows.api(Self.rows())
        _ = try await api.perform(.setRecurring(SetRecurring(merchant: "Spotify Usa", isRecurring: true, kind: .bill)))
        let spotify = try #require(try await api.subscriptions().items.first { $0.merchant == "Spotify Usa" })
        #expect(spotify.kind == .bill && spotify.cadence == .monthly && spotify.setByPerson == true)
        await #expect(throws: BudgetAPIError.rejected("Say how often Origin Financial repeats.")) {
            try await api.perform(.setRecurring(SetRecurring(merchant: "Origin Financial", isRecurring: true, kind: .subscription)))
        }
        await #expect(throws: BudgetAPIError.rejected("No charges from Nobody to go on.")) {
            try await api.perform(.setRecurring(SetRecurring(merchant: "Nobody", isRecurring: false)))
        }
    }

    @Test("A merchant on the recurring list counts as its kind whatever its category; taken off, it's its category's again")
    func buckets() throws {
        var ledger = Rows.ledger(Self.rows())
        let brenda = try #require(ledger.row("brenda-3"))
        #expect(ledger.bucket(of: brenda) == .subscriptions)
        _ = try ledger.perform(.setRecurring(SetRecurring(merchant: "Brendas Meat", isRecurring: true, kind: .bill)))
        #expect(ledger.bucket(of: brenda) == .bills)
        _ = try ledger.perform(.setRecurring(SetRecurring(merchant: "Brendas Meat", isRecurring: false)))
        #expect(ledger.bucket(of: brenda) == .everyday)
    }

    @Test("A cadence the person gives covers the charge that recurs, not everything from the merchant")
    func onlyTheRecurringCharge() throws {
        var ledger = Rows.ledger(Self.rows() + [
            Rows.row("prime", "card", 30, -139, "AMAZON", "shopping"),
            Rows.row("order-1", "card", 8, -42.10, "AMAZON", "shopping"),
            Rows.row("order-2", "card", 3, -18.99, "AMAZON", "shopping"),
        ])
        _ = try ledger.perform(.setRecurring(SetRecurring(merchant: "Amazon", isRecurring: true, cadence: .yearly, amount: DecimalAmount(Money(139)))))
        #expect(ledger.yearlyIDs.contains("prime") && !ledger.yearlyIDs.contains("order-1"))
        #expect(ledger.bucket(of: try #require(ledger.row("prime"))) == .subscriptions)
        #expect(ledger.bucket(of: try #require(ledger.row("order-2"))) == .everyday)
        #expect(ledger.subscriptions().items.first { $0.merchant == "Amazon" }?.charges == 1)
    }

    @Test("Undo puts the previous choice back exactly, cleared fields and all")
    func exactUndo() async throws {
        let api = Rows.api(Self.rows())
        _ = try await api.perform(.setRecurring(SetRecurring(merchant: "Spotify Usa", isRecurring: true, kind: .bill)))
        let second = try await api.perform(.setRecurring(SetRecurring(merchant: "Spotify Usa", isRecurring: true, cadence: .yearly)))
        _ = try await api.perform(try #require(second.undo))
        let spotify = try #require(try await api.subscriptions().items.first { $0.merchant == "Spotify Usa" })
        #expect(spotify.kind == .bill && spotify.cadence == .monthly)
    }

    @Test("Renaming a merchant takes its recurring choice along; undo takes it back")
    func renameCarriesChoice() throws {
        var ledger = Rows.ledger(Self.rows())
        _ = try ledger.perform(.setRecurring(SetRecurring(merchant: "Brendas Meat", isRecurring: false)))
        let ids = ledger.transactions.filter { $0.merchant == "Brendas Meat" }.map(\.id)
        let rename = try ledger.perform(.editTransactions(EditTransactions(transactionIDs: ids, merchant: "Brenda's")))
        #expect(ledger.recurringChoices["brenda's"]?.isRecurring == false && ledger.recurringChoices["brendas meat"] == nil)
        #expect(!ledger.subscriptions().items.contains { $0.merchant == "Brenda's" })
        _ = try ledger.perform(try #require(rename.undo))
        #expect(ledger.recurringChoices["brendas meat"]?.isRecurring == false && ledger.recurringChoices["brenda's"] == nil)
    }

    @Test("Names the bank takes turns with are one merchant, odd months and all; plans charging side by side, other shops and different-sized charges stay apart")
    func sameMerchantNames() throws {
        let ledger = Rows.ledger([
            Rows.row("fi-1", "card", 210, -75.11, "GOOGLE*FI GOO G.CO HELPPAY#", "utilities"),
            Rows.row("fi-2", "card", 180, -188.22, "GOOGLE *FI G.CO/HELPPAY# CA", "utilities"),
            Rows.row("fi-3", "card", 150, -75.33, "GOOGLE *FI G.CO/HELPPAY# CA", "utilities"),
            Rows.row("fi-4", "card", 120, -75.44, "GOOGLE*FI GOO G.CO HELPPAY#", "utilities"),
            Rows.row("fi-5", "card", 90, -75.44, "GOOGLE *FI IJ56KL G.CO/HELPPAY# CA", "utilities"),
            Rows.row("fi-6", "card", 60, -75.55, "GOOGLE *FI G.CO/HELPPAY# CA", "utilities"),
            Rows.row("fi-7", "card", 30, -50.66, "GOOGLE *FI G.CO/HELPPAY# CA", "utilities"),
            Rows.row("rf-1", "card", 95, -55.55, "PLAN FEE - EXAMPLE FINANCE", "fees"),
            Rows.row("rf-2", "card", 65, -55.55, "PLAN FEE - EXAMPLE FINANCE", "fees"),
            Rows.row("rf-3", "card", 35, -55.55, "PLAN FEE - EXAMPLE FINANCE", "fees"),
            Rows.row("ik-1", "card", 100, -66.66, "PLAN FEE - EXAMPLE COACHING", "fees"),
            Rows.row("ik-2", "card", 70, -66.66, "PLAN FEE - EXAMPLE COACHING", "fees"),
            Rows.row("ik-3", "card", 40, -66.66, "PLAN FEE - EXAMPLE COACHING", "fees"),
            Rows.row("prime-1", "card", 70, -14.99, "AMAZON PRIME", "shopping"),
            Rows.row("prime-2", "card", 40, -14.99, "AMAZON PRIME", "shopping"),
            Rows.row("prime-3", "card", 10, -14.99, "AMAZON PRIME", "shopping"),
            Rows.row("order-1", "card", 50, -62.40, "AMAZON", "shopping"),
            Rows.row("etsy-1", "card", 80, -13.33, "ETSY.COM*EXAMPLEFINDINGS", "shopping"),
            Rows.row("etsy-2", "card", 20, -14.50, "ETSY.COM*EXAMPLEWOOL", "shopping"),
        ])
        // The merchant names the bank data gives (its codes already stripped), three ways.
        let items = ledger.subscriptions().items
        let fi = try #require(items.first { $0.merchant.lowercased().hasPrefix("google") })
        #expect(fi.cadence == .monthly && fi.charges == 7 && fi.status == .active)
        #expect(items.filter { $0.merchant.lowercased().hasPrefix("google") }.count == 1)
        #expect(items.contains { $0.merchant == "Plan Fee - Example Finance" } && items.contains { $0.merchant == "Plan Fee - Example Coaching" })
        #expect(items.first { $0.merchant == "Amazon Prime" }?.charges == 3)
        #expect(Ledger.sameMerchants(ledger.transactions)["Etsy.Com*Examplewool"] == nil)
    }

    @Test("Two visits a year apart to a restaurant aren't a yearly subscription; a quarterly charge that repeats to the cent is")
    func everydayTwoCharges() {
        let ledger = Rows.ledger([
            Rows.row("hummus-1", "card", 380, -60.06, "EXAMPLE HUMMUS", "dining"),
            Rows.row("hummus-2", "card", 15, -58.08, "EXAMPLE HUMMUS", "dining"),
            Rows.row("im8-1", "card", 110, -222.22, "EXAMPLE VITAMINS", "health"),
            Rows.row("im8-2", "card", 18, -222.22, "EXAMPLE VITAMINS", "health"),
        ])
        let items = ledger.subscriptions().items
        #expect(!items.contains { $0.merchant == "Example Hummus" })
        #expect(items.first { $0.merchant == "Example Vitamins" }?.cadence == .quarterly)
        #expect(!ledger.yearlyIDs.contains("hummus-2"))
    }

    @Test("A monthly charge three months past its last one leaves the list; its charges keep their bucket")
    func staleLeaves() throws {
        let ledger = Rows.ledger([
            Rows.row("gym-1", "card", 200, -347, "TRIBE FITNESS", "health"),
            Rows.row("gym-2", "card", 170, -347, "TRIBE FITNESS", "health"),
            Rows.row("gym-3", "card", 140, -347, "TRIBE FITNESS", "health"),
            Rows.row("gym-4", "card", 110, -347, "TRIBE FITNESS", "health"),
            Rows.row("app-1", "card", 110, -20, "CLAUDE AI", "shopping"),
            Rows.row("app-2", "card", 80, -20, "CLAUDE AI", "shopping"),
            Rows.row("app-3", "card", 50, -20, "CLAUDE AI", "shopping"),
        ])
        let items = ledger.subscriptions().items
        #expect(!items.contains { $0.merchant == "Tribe Fitness" })
        // Late but not three months late: still listed, as missed.
        #expect(items.first { $0.merchant == "Claude Ai" }?.status == .missed)
        #expect(ledger.bucket(of: try #require(ledger.row("gym-4"))) == .subscriptions)
    }

    @Test("Choices are saved with the ledger and read back")
    func persisted() throws {
        var ledger = Rows.ledger(Self.rows())
        _ = try ledger.perform(.setRecurring(SetRecurring(merchant: "Brendas Meat", isRecurring: false)))
        let data = try JSONEncoder().encode(ledger.state)
        let state = try JSONDecoder().decode(LedgerState.self, from: data)
        #expect(state.recurringChoices["brendas meat"] == RecurringChoice(merchant: "Brendas Meat", isRecurring: false))
    }
}

@Suite("Budget months from older servers")
struct LegacyBudgetMonthTests {
    @Test("A 0.2 budget month reads: fixed costs still to come, and flexible and non-monthly as one everyday group")
    func decodesOld() throws {
        func money(_ minor: Int) -> [String: Any] { ["minor": minor, "currency": "USD"] }
        func group(_ name: String, _ planned: Int, _ spent: Int) -> [String: Any] {
            ["group": name, "planned": money(planned), "spent": money(spent), "categories": []]
        }
        let flex: [String: Any] = ["expectedIncome": money(500_000), "fixed": money(200_000), "nonMonthly": money(30_000),
                                   "plannedSavings": money(50_000), "plannedSavingsIsSet": false, "flexNumber": money(220_000),
                                   "flexSpent": money(100_000), "safeToSpend": money(120_000), "daysLeft": 5]
        let old: [String: Any] = ["month": "2026-09", "isCurrent": true, "flex": flex, "summary": "",
                                  "groups": [group("fixed", 200_000, 150_000), group("flexible", 220_000, 100_000), group("nonMonthly", 30_000, 0)],
                                  "unallocatedFlex": money(0), "everythingElseSpent": money(0), "fixedStillToCome": money(50_000)]
        let month = try JSONDecoder().decode(BudgetMonth.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(month.stillToCome == Money(500))
        #expect(month.groups.map(\.group) == [.bills, .everyday])
        #expect(month.groups[1].planned == Money(2500) && month.flex.bills == Money(2300))
    }
}
