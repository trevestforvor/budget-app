import Foundation
import Testing
@testable import BudgetKit

extension Rows {
    static func tag(_ ids: [String], add: [String]? = nil, remove: [String]? = nil) -> AppAction {
        .editTransactions(EditTransactions(transactionIDs: ids, addTags: add, removeTags: remove))
    }

    static func tagged(_ row: LedgerTransaction, _ tags: [String]) -> LedgerTransaction {
        var row = row
        row.tags = tags
        return row
    }
}

@Suite("Tags")
struct TagsTests {
    @Test("A tag is trimmed, its spaces collapsed and a leading # dropped; tags compare without case")
    func normalizing() {
        #expect(TransactionTags.normalize("  #Austin   trip ") == "Austin trip")
        #expect(TransactionTags.normalize(" # ") == nil)
        #expect(TransactionTags.cleaned(["Austin trip", "austin TRIP", "", "Work"]) == ["Austin trip", "Work"])
        #expect(TransactionTags.contains(["Austin trip"], "#austin trip"))
        #expect(TransactionTags.merged(["Work"], ["work", "Trip"]) == ["Work", "Trip"])
        #expect(TransactionTags.merged(nil, []) == nil)
    }

    @Test("Rows stored or cached before tags decode without them, and a row without tags writes no key")
    func legacyRows() throws {
        let json = #"{"id":"r","accountID":"chk","postedAt":0,"merchant":"Harvest Table","rawDescription":"HARVEST TABLE","amount":{"minor":-1000,"currency":"USD"},"isPending":false,"source":"plaid"}"#
        let row = try JSONDecoder().decode(LedgerTransaction.self, from: Data(json.utf8))
        #expect(row.tags == nil)
        #expect(!String(decoding: try JSONEncoder().encode(row), as: UTF8.self).contains("tags"))
        let tagged = Rows.tagged(row, ["Austin trip"])
        #expect(try JSONDecoder().decode(LedgerTransaction.self, from: JSONEncoder().encode(tagged)) == tagged)
        // A filter from an older client has no tags either.
        #expect(try JSONDecoder().decode(TransactionFilter.self, from: Data("{}".utf8)).tags == nil)
    }

    @Test("Adding tags previews, writes the ledger's own spelling, and undo puts the rows back exactly")
    func addAndUndo() throws {
        let rows = [Rows.row("a", "card", 1, -120, "UNITED AIRLINES", "travel"),
                    Rows.row("b", "card", 2, -40, "UBER *TRIP", "transport"),
                    Rows.tagged(Rows.row("c", "card", 3, -15, "HEARTH BAKERY", "dining"), ["Austin trip"])]
        var ledger = Rows.ledger(rows)
        let preview = try ledger.preview(Rows.tag(["a", "b"], add: ["#austin TRIP", "Work"]))
        #expect(preview.title == "Tag 2 transactions “Austin trip” and “Work”")
        #expect(preview.matchCount == 2 && preview.changeCount == nil)
        let result = try ledger.perform(Rows.tag(["a", "b"], add: ["#austin TRIP", "Work"]))
        #expect(result.message == "Tagged 2 transactions “Austin trip” and “Work”.")
        #expect(ledger.row("a")?.tags == ["Austin trip", "Work"])
        #expect(ledger.row("c")?.tags == ["Austin trip"])

        // Adding one already there keeps it once; removing ignores case; taking off the last leaves no tags at all.
        _ = try ledger.perform(Rows.tag(["a"], add: ["work"]))
        #expect(ledger.row("a")?.tags == ["Austin trip", "Work"])
        let removed = try ledger.perform(Rows.tag(["a", "c"], remove: ["AUSTIN TRIP"]))
        #expect(removed.message == "Tag removed.")
        #expect(ledger.row("a")?.tags == ["Work"] && ledger.row("c")?.tags == nil)

        _ = try ledger.perform(try #require(removed.undo))
        #expect(ledger.row("a")?.tags == ["Austin trip", "Work"] && ledger.row("c")?.tags == ["Austin trip"])
        _ = try ledger.perform(try #require(result.undo))
        #expect(ledger.transactions == Rows.ledger(rows).transactions)
    }

    @Test("Tag edits that can't be kept are refused, saying why")
    func refusals() throws {
        let rows = [Rows.tagged(Rows.row("a", "card", 1, -12, "OLIVE GRILL", "dining"), (1...9).map { "Tag \($0)" })]
        let ledger = Rows.ledger(rows)
        #expect(throws: BudgetAPIError.rejected("Nothing to change.")) { try ledger.preview(Rows.tag(["a"], add: ["  ", "#"])) }
        #expect(throws: BudgetAPIError.rejected("Add the tag “Work” or remove it, not both.")) {
            try ledger.preview(Rows.tag(["a"], add: ["Work"], remove: ["work"]))
        }
        #expect(throws: BudgetAPIError.rejected("A transaction holds up to 10 tags; Olive Grill would have more.")) {
            try ledger.preview(Rows.tag(["a"], add: ["Ten", "Eleven"]))
        }
        #expect(throws: BudgetAPIError.self) { try ledger.preview(Rows.tag(["a"], add: [String(repeating: "x", count: 33)])) }
        #expect(throws: Never.self) { try ledger.preview(Rows.tag(["a"], add: ["Ten"])) }
    }

    @Test("An undo made before tags existed leaves a row's tags alone")
    func legacyUndo() throws {
        var ledger = Rows.ledger([Rows.tagged(Rows.row("a", "card", 1, -12, "OLIVE GRILL", "dining"), ["Work"])])
        let undo = try #require(try ledger.perform(Rows.edit(["a"], note: "Lunch")).undo)
        guard case var .restoreTransactions(restore) = undo else { Issue.record("not a restore"); return }
        #expect(restore.rows[0].tags == ["Work"])
        restore.rows[0].tags = nil // as an app from before tags sends it back
        _ = try ledger.perform(.restoreTransactions(restore))
        #expect(ledger.row("a")?.note == nil && ledger.row("a")?.tags == ["Work"])
    }

    @Test("The tag filter matches any of its tags without case; search finds tags; the filter travels as repeated tag items")
    func filterAndSearch() throws {
        let ledger = Rows.ledger([Rows.tagged(Rows.row("a", "card", 1, -120, "UNITED AIRLINES", "travel"), ["Austin trip"]),
                                  Rows.tagged(Rows.row("b", "card", 2, -40, "UBER *TRIP", "transport"), ["Work"]),
                                  Rows.row("c", "card", 3, -15, "HEARTH BAKERY", "dining")])
        #expect(ledger.matching(TransactionFilter(tags: ["austin TRIP"])).map(\.id) == ["a"])
        #expect(ledger.matching(TransactionFilter(tags: ["austin trip", "work"])).map(\.id) == ["a", "b"])
        #expect(ledger.matching(TransactionFilter(tags: [])).count == 3)
        #expect(ledger.matching(TransactionFilter(search: "austin")).map(\.id) == ["a"])
        let filter = TransactionFilter(period: "this_month", limit: 50, tags: ["Austin trip", "Work"])
        #expect(filter.queryItems.filter { $0.name == "tag" }.map(\.value) == ["Austin trip", "Work"])
        #expect(try TransactionFilter(queryItems: filter.queryItems, calendar: Fixture.calendar) == filter)
        #expect(!filter.isDefault && TransactionFilter(limit: 200, tags: []).isDefault)
    }

    @Test("A tag's totals follow the Spending tab: refunds net within their category, hidden rows and transfers left out, money in as income")
    func totals() throws {
        let trip = ["Austin trip"]
        let ledger = Rows.ledger([
            Rows.tagged(Rows.row("flight", "card", 10, -100, "UNITED AIRLINES", "travel"), trip),
            Rows.tagged(Rows.row("refund", "card", 9, 30, "UNITED AIRLINES", "travel"), trip),
            Rows.tagged(Rows.row("meal", "card", 8, -20, "HEARTH BAKERY", "dining"), trip),
            Rows.tagged(Rows.row("hidden", "card", 7, -50, "OLIVE GRILL", "dining", hidden: true), trip),
            Rows.tagged(Rows.row("move", "chk", 6, -200, "ONLINE TRANSFER TO SAV", "transfer"), trip),
            Rows.tagged(Rows.row("paid back", "chk", 5, 500, "ACME CORP PAYROLL", "income"), trip),
            Rows.tagged(Rows.row("lunch", "card", 40, -18, "OLIVE GRILL", "dining"), ["Work"]),
            Rows.row("untagged", "card", 1, -999, "TARGET 00027", "shopping"),
        ])
        let summary = try ledger.tagSummary("austin trip")
        #expect(summary.tag == "Austin trip" && summary.count == 6)
        #expect(summary.spent == Money(90) && summary.income == Money(500))
        #expect(summary.byCategory == [.init(categoryID: "travel", spent: Money(70)), .init(categoryID: "dining", spent: Money(20))])
        #expect(summary.earliest == EngineFixture.day(10) && summary.latest == EngineFixture.day(5))
        // The list leaves spending by category out and puts the most recently used first.
        let all = try ledger.tagSummaries()
        #expect(all.map(\.tag) == ["Austin trip", "Work"] && all.allSatisfy { $0.byCategory == nil })
        #expect(try ledger.tagSummaries(period: "last_30_days").map(\.tag) == ["Austin trip"])
        #expect(throws: BudgetAPIError.notFound) { try ledger.tagSummary("Nope") }
        #expect(throws: BudgetAPIError.rejected("Unknown period “someday”.")) { try ledger.tagSummaries(period: "someday") }
    }

    @Test("A posted row keeps the pending row's tags, and the synced copy of an imported row gains its tags")
    func carriedOver() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions(["BLUE BOTTLE": ("dining", 0.95)])))
        func snapshot(_ rows: [SourceTransaction]) -> SourceSnapshot {
            SourceSnapshot(source: .plaid, accounts: [
                SourceAccount(externalID: "summit-1", institution: "Bank", institutionDomain: nil, name: "Card", kind: .credit, balance: .zero,
                              availableBalance: nil, balanceDate: EngineFixture.now, transactions: rows, holdings: []),
            ], warnings: [])
        }
        let pending = SourceTransaction(externalID: "q1", posted: EngineFixture.day(2), amount: Money(-6.5), description: "BLUE BOTTLE COFFEE 0423",
                                        payee: "Blue Bottle", isPending: true)
        _ = try await api.ingest(snapshot([pending]), batchID: "sync-1")
        _ = try await api.perform(Rows.tag(["plaid:q1"], add: ["Work"]))
        let posted = SourceTransaction(externalID: "q2", posted: EngineFixture.day(1), amount: Money(-6.5), description: "BLUE BOTTLE COFFEE 0423",
                                       payee: "Blue Bottle", replacesExternalID: "q1")
        _ = try await api.ingest(snapshot([posted]), batchID: "sync-2")
        #expect(try await api.transaction(id: "plaid:q2").tags == ["Work"])

        var file = Rows.tagged(Rows.row("file", "card", 3, -40, "OLIVE GRILL", "dining"), ["Work", "Lunch"])
        file.source = .fileImport
        let synced = Rows.tagged(Rows.row("synced", "card", 3, -40, "OLIVE GRILL", "dining"), ["work"])
        var ledger = Rows.ledger([file, synced])
        #expect(ledger.removeDuplicates([(file, synced)]) == 1)
        #expect(ledger.row("synced")?.tags == ["work", "Lunch"])
    }

    @Test("The demo tags its Austin trip and what work paid back, without moving a total")
    func demo() throws {
        let ledger = Fixture.ledger()
        let trip = try ledger.tagSummary("Austin trip")
        let rows = ledger.matching(TransactionFilter(tags: ["Austin trip"]))
        #expect(rows.contains { $0.merchant == "United Airlines" } && rows.contains { $0.merchant == "Riverside Hotel" })
        #expect(trip.spent.minorUnits >= Money(1098.20).minorUnits)
        #expect(trip.byCategory?.first?.categoryID == "travel")
        // The team dinner is hidden, so "Reimbursable" counts only the Uber ride.
        let paidBack = try ledger.tagSummary("Reimbursable")
        let uber = try #require(ledger.matching(TransactionFilter(tags: ["Reimbursable"])).first { $0.merchant == "Uber" })
        #expect(paidBack.count == 2 && paidBack.spent == uber.amount.magnitude)
    }
}

@Suite("Tags in Ask")
struct TagAskTests {
    @Test("sumByTag reads one tag with spending by category, or every tag; queryTransactions narrows by tag and lists tags")
    func tools() async throws {
        let toolbox = DemoToolbox(ledger: Fixture.ledger(), decisions: nil)
        let one = try await toolbox.run(read: "sumByTag", arguments: .object(["tag": .string("austin trip")]))
        guard case let .object(o) = one.result, case let .array(byCategory)? = o["byCategory"] else { Issue.record("no result"); return }
        #expect(o["tag"] == .string("Austin trip") && !byCategory.isEmpty)
        #expect(one.figures.first?.value == (try Fixture.ledger().tagSummary("Austin trip")).spent)
        let all = try await toolbox.run(read: "sumByTag", arguments: .object([:]))
        guard case let .object(list) = all.result else { Issue.record("no list"); return }
        #expect(list["count"] == .number(2))
        let missing = try await toolbox.run(read: "sumByTag", arguments: .object(["tag": .string("Paris")]))
        guard case let .object(m) = missing.result else { Issue.record("no answer"); return }
        #expect(m["found"] == .bool(false))

        let query = try await toolbox.run(read: "queryTransactions", arguments: .object(["tag": .string("Reimbursable")]))
        guard case let .object(q) = query.result, case let .array(rows)? = q["rows"] else { Issue.record("no rows"); return }
        #expect(q["count"] == .number(2))
        #expect(rows.allSatisfy { if case let .object(r) = $0, case let .array(tags)? = r["tags"] { tags.contains(.string("Reimbursable")) } else { false } })
    }

    @Test("Asking what a tag cost answers from sumByTag, grounded in its own figures", arguments: [
        "How much did the Austin trip cost?", "What have I tagged?",
    ])
    func demoAnswer(question: String) async throws {
        let reply = try await Fixture.api().ask(question, conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["sumByTag"])
        for call in reply.toolCalls {
            #expect(throws: Never.self) { try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8)) }
        }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
    }

    @Test("A tag answers only as its own words, and a tag spelled like a category leaves the question to the category")
    func tagIntentScope() async throws {
        #expect(DemoAskEngine.containsWords("how much for the work trip?", "work"))
        #expect(!DemoAskEngine.containsWords("what's my network bill?", "work"))
        #expect(DemoAskEngine.containsWords("work", "work") && !DemoAskEngine.containsWords("work2", "work"))
        let api = Fixture.api()
        let travel = try #require(Fixture.ledger().transactions.first { $0.categorization?.categoryID == "dining" && !$0.isPending })
        _ = try await api.perform(Rows.tag([travel.id], add: ["Travel", "Work"]))
        #expect(try await api.ask("How much did I spend on travel last month?", conversationID: nil).toolCalls.map(\.name) != ["sumByTag"])
        #expect(try await api.ask("What's my network spending?", conversationID: nil).toolCalls.map(\.name) != ["sumByTag"])
        #expect(try await api.ask("What did the Travel tag cost?", conversationID: nil).toolCalls.map(\.name) == ["sumByTag"])
        #expect(try await api.ask("How much went on work?", conversationID: nil).toolCalls.map(\.name) == ["sumByTag"])
    }

    @Test("Tag edits round-trip as tool calls", arguments: [
        AppAction.editTransactions(EditTransactions(transactionIDs: ["tx-1", "tx-2"], addTags: ["Austin trip"])),
        AppAction.editTransactions(EditTransactions(transactionIDs: ["tx-3"], removeTags: ["Work"])),
        AppAction.editTransactions(EditTransactions(transactionIDs: ["tx-4"], categoryID: "dining", fileSimilar: true)),
    ])
    func roundTrip(action: AppAction) throws {
        let decoded = try AppAction(toolName: action.toolName, arguments: try action.argumentsJSON(), categoryIDs: DemoLedger.categoryList.map(\.id))
        #expect(decoded == action)
        // The wire form the app posts to /v1/actions carries the new fields too.
        let wire = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(AppAction.self, from: wire) == action)
    }
}
