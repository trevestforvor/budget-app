@testable import BudgetKit
import Foundation
import Testing

@Suite("Checkup")
struct CheckupTests {
    @Test("The demo ledger's checkup covers every section with ledger figures")
    func demo() async throws {
        let api = LedgerBudgetAPI(latency: .zero)
        let checkup = try await api.checkup()
        let ids = checkup.sections.map(\.id)
        #expect(ids.contains("month") && ids.contains("categories") && ids.contains("saving") && ids.contains("recurring"))
        #expect(!checkup.headline.isEmpty)
        if ProcessInfo.processInfo.environment["PRINT_CHECKUP"] != nil {
            print("HEADLINE:", checkup.headline)
            for s in checkup.sections {
                print("== \(s.title) [\(s.status.rawValue)]")
                for f in s.findings { print("  [\(f.status.rawValue)] \(f.title)\(f.detail.map { " — " + $0 } ?? "")") }
            }
        }
    }

    @Test("Every finding opens the screen it's about, or its figures do; the outlook shows each month it averages")
    func links() async throws {
        let checkup = try await LedgerBudgetAPI(latency: .zero).checkup()
        let findings = checkup.sections.flatMap(\.findings)
        // Hidden rows are only a note: nothing to open.
        for finding in findings where finding.id != "hidden" {
            #expect(finding.link != nil || finding.metrics.contains { $0.link != nil }, "\(finding.id) opens nothing")
        }
        let top = try #require(findings.first { $0.id == "top-merchants" })
        #expect(top.metrics.allSatisfy { $0.link == .merchant($0.label) })
        let outlook = try #require(findings.first { $0.id == "outlook" })
        #expect(outlook.link == .plan)
        let calendar = Fixture.calendar
        let start = calendar.dateInterval(of: .month, for: checkup.asOf)!.start
        let names = (1...3).reversed().map { calendar.date(byAdding: .month, value: -$0, to: start)!.formatted(Ledger.monthStyle(calendar, year: false)) }
        #expect(outlook.metrics.map(\.label) == names + ["In six months"])
        #expect(outlook.title.hasPrefix("From \(names[0]) to \(names[2]), "))

        // On the wire: {"to": …, "id": …}; one this build doesn't know opens nothing instead of failing the checkup.
        let wire = try JSONEncoder().encode(Checkup.Link.category("dining"))
        #expect(try JSONSerialization.jsonObject(with: wire) as? [String: String] == ["to": "category", "id": "dining"])
        #expect(try JSONDecoder().decode(Checkup.Link.self, from: Data(#"{"to": "somewhere-new"}"#.utf8)) == .unknown)
        let round = try JSONDecoder().decode(Checkup.self, from: JSONEncoder().encode(checkup))
        #expect(round == checkup)
    }

    @Test("Subscriptions: found from repeat charges, with cadence, totals and the next charge")
    func subscriptions() async throws {
        let api = LedgerBudgetAPI(latency: .zero)
        let found = try await api.subscriptions()
        let names = found.items.map(\.merchant)
        #expect(names.contains("Netflix") && names.contains("Spotify"))
        #expect(found.items.first { $0.merchant == "Netflix" }?.cadence == .monthly)
        // A shopping habit isn't recurring; a monthly utility is a bill, even one that moves with the season.
        #expect(!names.contains("Uniqlo"))
        #expect(found.items.first { $0.merchant == "City Power" }.map { $0.kind == .bill && $0.cadence == .monthly } == true)
        #expect(found.subscriptionsMonthly.minorUnits > 0)
        if ProcessInfo.processInfo.environment["PRINT_CHECKUP"] != nil {
            for s in found.items { print("SUB", s.kind.rawValue, s.cadence.rawValue, s.status.rawValue, s.merchant, s.amount.formatted(), "next", s.nextExpected.formatted(date: .abbreviated, time: .omitted)) }
            print("SUB totals", found.subscriptionsMonthly.formatted(), "/mo subs;", found.billsMonthly.formatted(), "/mo bills")
        }
        let reply = try await api.ask("What subscriptions am I paying for?", conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["findSubscriptions"])
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty)
    }

    @Test("An empty ledger says so instead of inventing findings")
    func empty() throws {
        let checkup = Ledger(state: .empty, now: .now, calendar: .current).checkup()
        #expect(checkup.sections.flatMap(\.findings).contains { $0.id == "no-data" && $0.status == .act })
    }

    @Test("A short history with no cash account doesn't raise false alarms")
    func shortHistory() throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Gold Card", institution: "Summit", kind: .credit, balance: Money(-400), source: .fileImport)]
        state.transactions = (0..<5).map { i in
            LedgerTransaction(id: "t\(i)", accountID: "card", postedAt: Date().addingTimeInterval(Double(-i) * 86_400), merchant: "Shop \(i)",
                              rawDescription: "SHOP \(i)", amount: Money(-300), categorization: nil, isPending: false, source: .fileImport)
        }
        let checkup = Ledger(state: state, now: .now, calendar: .current).checkup()
        let findings = checkup.sections.flatMap(\.findings)
        #expect(!findings.contains { $0.id == "cushion" })             // no cash account: not "0.0 months"
        #expect(findings.contains { $0.id == "no-cash-accounts" })
        #expect(!checkup.sections.contains { $0.id == "outlook" })    // not enough history to project
        #expect(!findings.contains { $0.id.hasPrefix("large-") })     // everything is "new" in week one
        #expect(findings.contains { $0.title == "Less than a month of history." })
        #expect(!findings.contains { ["plan-ok", "plan-too-high", "saving-unplanned", "no-plan"].contains($0.id) }) // needs complete months
    }

    @Test("Ask: “check everything” is one runCheckup call, and its amounts are grounded")
    func ask() async throws {
        let api = LedgerBudgetAPI(latency: .zero)
        let reply = try await api.ask("Can you check everything out?", conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["runCheckup"])
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty)
        #expect(ToolCatalog.specs.contains { $0.name == "runCheckup" && $0.kind == .read })
    }
}
