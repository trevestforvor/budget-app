import Foundation
import Testing
@testable import BudgetKit

@Suite("Cash-flow Sankey")
struct CashFlowSankeyTests {
    /// Every node takes in what it gives out, and each column adds up to the same total.
    static func expectBalanced(_ flow: CashFlowSankey, sourceLocation: SourceLocation = #_sourceLocation) {
        let columns = (0...2).map { c in flow.nodes.filter { $0.column == c }.map(\.value).sum() }
        let total = flow.income + flow.drawnFromCash
        #expect(columns[0] == total, sourceLocation: sourceLocation)
        #expect(columns[1] == total, sourceLocation: sourceLocation)
        #expect(total == flow.spending + flow.saved, sourceLocation: sourceLocation)
        #expect(columns[2] == flow.spending, sourceLocation: sourceLocation)
        for node in flow.nodes {
            #expect(node.value.minorUnits > 0, "\(node.id)", sourceLocation: sourceLocation)
            switch node.column {
            case 0: #expect(flow.outflow(node.id) == node.value, "\(node.id)", sourceLocation: sourceLocation)
            case 1:
                #expect(flow.inflow(node.id) == node.value, "\(node.id)", sourceLocation: sourceLocation)
                if node.kind == .bucket { #expect(flow.outflow(node.id) == node.value, "\(node.id)", sourceLocation: sourceLocation) }
            default: #expect(flow.inflow(node.id) == node.value, "\(node.id)", sourceLocation: sourceLocation)
            }
        }
        #expect(flow.links.allSatisfy { $0.value.minorUnits > 0 }, sourceLocation: sourceLocation)
        #expect(Set(flow.nodes.map(\.id)).count == flow.nodes.count, sourceLocation: sourceLocation)
        #expect(flow.saved.minorUnits == 0 || flow.drawnFromCash.minorUnits == 0, sourceLocation: sourceLocation)
    }

    @Test("Every month of the demo balances, and its buckets and income are the budget's and cash flow's to the cent")
    func demoMonths() throws {
        let ledger = Fixture.ledger()
        let history = ledger.cashFlowHistory(months: 6)
        for month in history {
            let key: String? = month.isPartial ? nil : month.month
            let flow = try ledger.cashFlowSankey(month: key)
            #expect(flow.month == month.month && flow.isPartial == month.isPartial)
            Self.expectBalanced(flow)
            #expect(flow.income == month.income, "\(month.month)")
            let budget = try ledger.budgetMonth(key)
            for group in budget.groups {
                let node = flow.node("bucket-\(group.group.rawValue)")
                #expect((node?.value ?? .zero) == group.spent, "\(month.month) \(group.group)")
            }
            #expect(flow.spending == budget.groups.map(\.spent).sum())
            #expect(flow.saved == Money(minorUnits: max(0, (flow.income - flow.spending).minorUnits)))
        }
    }

    @Test("Income comes from its payers, largest first; buckets come in budget order with Saved last")
    func order() throws {
        let flow = try Fixture.ledger().cashFlowSankey(month: "2026-08")
        let sources = flow.nodes.filter { $0.column == 0 }
        #expect(sources.first?.label == "Acme Corp")
        #expect(sources.map(\.value) == sources.map(\.value).sorted(by: >) || sources.last?.kind == .drawn)
        let middle = flow.nodes.filter { $0.column == 1 }.map(\.id)
        #expect(middle == ["bucket-bills", "bucket-subscriptions", "bucket-everyday", "saved"].filter { id in flow.node(id) != nil })
        #expect(flow.nodes.filter { $0.column == 2 }.allSatisfy { $0.group != nil })
        #expect(flow.nodes.first { $0.categoryID == "groceries" }?.color == CategoryColor.azure.rawValue)
    }

    @Test("Spending past income is drawn from cash, and nothing is saved")
    func drawn() throws {
        let rows = [
            Rows.row("pay", "chk", 3, 1000, "ACME PAYROLL", "income"),
            Rows.row("rent", "chk", 4, -1400, "MAPLE CT APTS", "housing"),
            Rows.row("food", "card", 5, -120, "TRADER JOES", "groceries"),
        ]
        let flow = try Rows.ledger(rows).cashFlowSankey(month: nil)
        Self.expectBalanced(flow)
        #expect(flow.drawnFromCash == Money(520) && flow.saved == .zero)
        #expect(flow.node("drawn")?.label == "From cash" && flow.node("saved") == nil)
        // The paycheck fills Bills first; cash covers the rest.
        #expect(flow.links.filter { $0.source == "in-0" }.map(\.target) == ["bucket-bills"])
        #expect(flow.links.filter { $0.source == "drawn" }.map(\.value).sum() == Money(520))
    }

    @Test("A bucket names its four largest categories and puts two or more others together; a lone fifth is named")
    func topCategories() throws {
        let everyday = ["groceries", "dining", "transport", "shopping", "entertainment", "health", "travel"]
        func rows(_ ids: [String]) -> [LedgerTransaction] {
            [Rows.row("pay", "chk", 2, 9000, "ACME PAYROLL", "income")]
                + ids.enumerated().map { i, id in Rows.row("r\(i)", "card", Double(i + 3), Decimal(-100 * (i + 1)), "STORE \(id.uppercased())", id) }
        }
        let seven = try Rows.ledger(rows(everyday)).cashFlowSankey(month: nil)
        Self.expectBalanced(seven)
        let named = seven.nodes.filter { $0.kind == .category && $0.group == .everyday }
        #expect(named.map(\.categoryID) == ["travel", "health", "entertainment", "shopping"])
        #expect(seven.node("other-everyday")?.value == Money(600)) // 100 + 200 + 300
        #expect(seven.node("other-everyday")?.label == "Other everyday")

        let five = try Rows.ledger(rows(Array(everyday.prefix(5)))).cashFlowSankey(month: nil)
        Self.expectBalanced(five)
        #expect(five.nodes.filter { $0.kind == .category }.count == 5 && five.node("other-everyday") == nil)
    }

    @Test("Hidden rows and transfers stay out; a refund nets against its category, never below zero")
    func countedOnly() throws {
        let rows = [
            Rows.row("pay", "chk", 2, 3000, "ACME PAYROLL", "income"),
            Rows.row("hidden", "card", 3, -800, "BIG TV", "shopping", hidden: true),
            Rows.row("move", "chk", 4, -500, "TRANSFER TO SAV", "transfer"),
            Rows.row("dinner", "card", 5, -60, "HARVEST TABLE", "dining"),
            Rows.row("refund", "card", 6, 90, "HARVEST TABLE REFUND", "dining"),
            Rows.row("food", "card", 7, -40, "SAFEWAY", "groceries"),
        ]
        let flow = try Rows.ledger(rows).cashFlowSankey(month: nil)
        Self.expectBalanced(flow)
        #expect(flow.spending == Money(40))
        #expect(flow.node("cat-everyday-dining") == nil && flow.node("cat-everyday-shopping") == nil)
        #expect(flow.income == Money(3000) && flow.saved == Money(2960))
    }

    @Test("Many payers: four are named and the rest are Other income; a reversed deposit comes off the total")
    func sources() throws {
        let payers = ["ACME", "GLOBEX", "INITECH", "UMBRELLA", "HOOLI", "STARK"]
        var rows = payers.enumerated().map { i, p in Rows.row("p\(i)", "chk", Double(i + 1), Decimal(1000 - 100 * i), "\(p) PAYROLL", "income") }
        rows.append(Rows.row("back", "chk", 9, -200, "ACME PAYROLL", "income"))
        let flow = try Rows.ledger(rows).cashFlowSankey(month: nil)
        Self.expectBalanced(flow)
        #expect(flow.income == Money(4300)) // 1000 + 900 + 800 + 700 + 600 + 500 − 200
        let sources = flow.nodes.filter { $0.column == 0 }
        // Acme's reversed deposit leaves it level with Initech; a tie goes by name.
        #expect(sources.map(\.label) == ["Globex Payroll", "Acme Payroll", "Initech Payroll", "Umbrella Payroll", "Other income"])
        #expect(sources.last?.value == Money(1100))
        #expect(flow.node("saved")?.value == Money(4300))
    }

    @Test("An empty month has no nodes; a future or malformed month is refused")
    func edges() throws {
        let empty = try Rows.ledger([]).cashFlowSankey(month: nil)
        #expect(empty.nodes.isEmpty && empty.links.isEmpty && empty.income == .zero)
        #expect(throws: BudgetAPIError.rejected("October 2026 hasn't started yet.")) { try Fixture.ledger().cashFlowSankey(month: "2026-10") }
        #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try Fixture.ledger().cashFlowSankey(month: "Sept") }
    }

    @Test("Ask's monthFlow returns the Sankey's figures, and the demo answers flow questions with it")
    func ask() async throws {
        let reply = try await Fixture.api().ask("Where did my income go? Show the money flow", conversationID: nil)
        #expect(reply.toolCalls.first?.name == "monthFlow")
        for call in reply.toolCalls {
            try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8))
        }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
        #expect(reply.figures.first { $0.id == "flow-income" }?.value == (try Fixture.ledger().cashFlowSankey(month: nil)).income)

        let flow = try Fixture.ledger().cashFlowSankey(month: "2026-08")
        let out = try DemoToolbox(ledger: Fixture.ledger(), decisions: nil).monthFlow(month: "2026-08")
        try ToolCatalog.validateArguments(tool: "monthFlow", json: Data(#"{"month":"2026-08"}"#.utf8))
        #expect(out.figures.first { $0.id == "flow-income" }?.value == flow.income)
        #expect(out.figures.first { $0.id == "flow-bucket-everyday" }?.value == flow.node("bucket-everyday")?.value)
        let text = String(decoding: try out.result.data(), as: UTF8.self)
        #expect(Grounding.ungroundedAmounts(in: text, allowed: out.figures.map(\.value)).isEmpty, "\(text)")
    }

    @Test("The model decodes kinds a later version adds")
    func decoding() throws {
        let node = try JSONDecoder().decode(CashFlowSankey.Node.self, from: Data(#"{"id":"x","label":"X","kind":"investments","column":1,"value":{"minor":5,"currency":"USD"}}"#.utf8))
        #expect(node.kind == .other && node.group == nil && node.color == nil)
    }
}
