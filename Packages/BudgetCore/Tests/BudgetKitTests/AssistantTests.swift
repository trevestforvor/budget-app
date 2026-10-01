import Foundation
import Testing
@testable import BudgetKit

@Suite("Tool schemas")
struct ToolSchemaTests {
    static let samples: [AppAction] = [
        .setCategoryTarget(SetCategoryTarget(categoryID: "dining", monthlyAmount: DecimalAmount(string: "500")!)),
        .adjustCategoryTarget(AdjustCategoryTarget(categoryID: "groceries", change: DecimalAmount(string: "-25.50")!)),
        .removeCategoryTarget(RemoveCategoryTarget(categoryID: "shopping")),
        .setMerchantTarget(SetMerchantTarget(merchant: "DoorDash", monthlyAmount: DecimalAmount(string: "150")!)),
        .removeMerchantTarget(RemoveMerchantTarget(merchant: "DoorDash")),
        .setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(string: "1200")!)),
        .createCategory(CreateCategory(name: "Pets", symbol: "pawprint", monthlyTarget: DecimalAmount(string: "100")!)),
        .createCategory(CreateCategory(name: "Gifts")),
        .createCategory(CreateCategory(name: "Car", group: .bills, color: "teal")),
        .updateCategory(UpdateCategory(categoryID: "dining", name: "Eating out", color: "coral")),
        .updateCategory(UpdateCategory(categoryID: "subscriptions", group: .everyday)),
        .mergeCategory(MergeCategory(from: "entertainment", into: "shopping", combineTargets: true)),
        .createBudgetRule(CreateBudgetRule(match: .init(merchantContains: "venmo"), categoryID: "transfer", applyToExisting: true)),
        .createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "Withdrawal", direction: .moneyOut, minAmount: DecimalAmount(string: "100"),
                                                        maxAmount: DecimalAmount(string: "5000"), accountID: "plaid:wf-cash"),
                                           categoryID: "transfer", applyToExisting: false)),
        .updateBudgetRule(UpdateBudgetRule(ruleID: "rule-2", categoryID: "income", applyToExisting: true)),
        .updateBudgetRule(UpdateBudgetRule(ruleID: "rule-3", isEnabled: false)),
        .deleteBudgetRule(DeleteBudgetRule(ruleID: "rule-1")),
        .recategorize(Recategorize(transactionIDs: ["tx-1", "tx-2"], categoryID: "dining")),
        .editTransactions(EditTransactions(transactionIDs: ["tx-3"], isHidden: true, note: "Reimbursed by work")),
        .editTransactions(EditTransactions(transactionIDs: ["tx-4", "tx-5"], merchant: "Blue Bottle", renameSimilar: true)),
        .updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: 80)),
        .updateDecisionPolicy(UpdateDecisionPolicy(reviewNewMerchants: true, holdPending: true, reviewAbove: DecimalAmount(string: "500"))),
        .navigate(Navigate(screen: .spending, categoryID: "dining", range: .lastMonth)),
    ]

    @Test("Every tool has an object schema whose required fields exist")
    func wellFormed() {
        #expect(Set(ToolCatalog.specs.map(\.name)).count == ToolCatalog.specs.count)
        for spec in ToolCatalog.specs {
            #expect(spec.schema.kind == .object, "\(spec.name)")
            #expect(Set(spec.schema.required).isSubset(of: spec.schema.properties.keys), "\(spec.name)")
            #expect(!spec.description.isEmpty)
        }
    }

    @Test("Every AppAction case has a tool of the matching kind")
    func actionsHaveTools() {
        for action in Self.samples {
            let spec = ToolCatalog.spec(named: action.toolName)
            #expect(spec != nil, "\(action.toolName)")
            #expect(spec?.kind == (action.isClientOnly ? .client : .write))
        }
    }

    @Test("Encoded arguments validate against their own schema and decode back", arguments: samples)
    func roundTrip(action: AppAction) throws {
        let args = try action.argumentsJSON()
        let decoded = try AppAction(toolName: action.toolName, arguments: args, categoryIDs: DemoLedger.categoryList.map(\.id))
        #expect(decoded == action)
    }

    @Test("Wire form carries a type discriminator", arguments: samples)
    func wireForm(action: AppAction) throws {
        let data = try JSONEncoder().encode(action)
        guard case let .object(o) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        #expect(o["type"] == .string(action.toolName))
        #expect(try JSONDecoder().decode(AppAction.self, from: data) == action)
    }

    @Test("An undo travels on the wire but is never a tool the assistant can call")
    func undoIsNotATool() throws {
        let undo = AppAction.restoreTransactions(RestoreTransactions(
            rows: [.init(Fixture.ledger().transactions[0], suggestions: nil)], aliases: [.init(descriptor: "NETFLIX.COM", merchant: nil)],
            caps: [.init(merchant: "Netflix", monthlyAmount: DecimalAmount(string: "20"))]))
        let data = try JSONEncoder().encode(undo)
        #expect(try JSONDecoder().decode(AppAction.self, from: data) == undo)
        #expect(ToolCatalog.spec(named: undo.toolName) == nil)
        #expect(throws: ToolArgumentError.self) { try AppAction(toolName: undo.toolName, arguments: try undo.argumentsJSON()) }
    }

    @Test("Forgetting a merchant travels on the wire but isn't a tool; rule and category tools only take the ledger's live categories")
    func memoryAndCategoryFields() throws {
        let forget = AppAction.forgetMerchant(ForgetMerchant(descriptor: "CASA TACO"))
        #expect(try JSONDecoder().decode(AppAction.self, from: JSONEncoder().encode(forget)) == forget)
        #expect(ToolCatalog.spec(named: forget.toolName) == nil)
        let ids = ["dining", "shopping", "income"]
        let specs = ToolCatalog.specs(categoryIDs: ids, spendingCategoryIDs: ["dining", "shopping"])
        let merge = try #require(specs.first { $0.name == "mergeCategory" })
        #expect(merge.schema.properties["from"]?.enumValues == ["dining", "shopping"] && merge.schema.properties["into"]?.enumValues == ["dining", "shopping"])
        let update = try #require(specs.first { $0.name == "updateBudgetRule" })
        #expect(update.schema.properties["categoryID"]?.enumValues == ids)
        #expect(update.schema.properties["match"]?.properties["direction"]?.enumValues == ["out", "in"])
        #expect(throws: ToolArgumentError.self) {
            try AppAction(toolName: "mergeCategory", arguments: Data(#"{"from":"pets","into":"dining"}"#.utf8), categoryIDs: ids)
        }
        #expect(throws: ToolArgumentError.self) {
            try AppAction(toolName: "createBudgetRule", arguments: Data(#"{"match":{"direction":"out"},"categoryID":"dining","applyToExisting":false,"createdBy":"person"}"#.utf8))
        }
    }

    @Test("\"Charges over $500\" is minAmount and direction, not a text search for 500: the rows are the big charges")
    func amountFilters() async throws {
        func problems(_ json: String) -> [String] {
            do { try ToolCatalog.validateArguments(tool: "queryTransactions", json: Data(json.utf8), categoryIDs: nil); return [] }
            catch let error as ToolArgumentError { return error.problems }
            catch { return ["\(error)"] }
        }
        #expect(problems(#"{"minAmount":"500","direction":"out","since":"2026-08-01","until":"2026-09-01"}"#).isEmpty)
        #expect(problems(#"{"maxAmount":"19.99"}"#).isEmpty)
        #expect(problems(#"{"minAmount":"$500"}"#).first?.contains("must match") == true)
        #expect(problems(#"{"direction":"sideways"}"#).first?.contains("must be one of") == true)

        let ledger = Fixture.ledger()
        let (result, _) = try await DemoToolbox(ledger: ledger, decisions: nil)
            .run(read: "queryTransactions", arguments: .object(["minAmount": .string("500"), "direction": .string("out"), "limit": .number(200)]))
        guard case let .object(o) = result, case let .array(rows)? = o["rows"] else { Issue.record("no rows"); return }
        let big = ledger.transactions.filter { $0.amount.isNegative && $0.amount.magnitude >= Money(500) }
        #expect(!big.isEmpty && rows.count == min(big.count, 200))
        for case let .object(row) in rows {
            guard case let .string(id)? = row["id"], let found = ledger.transactions.first(where: { $0.id == id }) else { Issue.record("row"); continue }
            #expect(found.amount.isNegative && found.amount.magnitude >= Money(500))
        }
    }

    @Test("A query's until is the last day it includes: \"2026-08-31\" keeps August 31")
    func untilIsInclusive() async throws {
        let ledger = Fixture.ledger()
        let calendar = ledger.calendar
        let day = try #require(ledger.transactions.map { calendar.startOfDay(for: $0.postedAt) }.max(by: { $0 < $1 }))
        let iso = day.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
        let (result, _) = try await DemoToolbox(ledger: ledger, decisions: nil)
            .run(read: "queryTransactions", arguments: .object(["since": .string(iso), "until": .string(iso), "limit": .number(200)]))
        guard case let .object(o) = result, case let .number(count)? = o["count"] else { Issue.record("no count"); return }
        let thatDay = ledger.transactions.filter { calendar.isDate($0.postedAt, inSameDayAs: day) }
        #expect(!thatDay.isEmpty && Int(count) == thatDay.count)
    }

    @Test("Bad arguments are rejected with repairable messages")
    func rejects() {
        func problems(_ tool: String, _ json: String, ids: [String]? = nil) -> [String] {
            do { try ToolCatalog.validateArguments(tool: tool, json: Data(json.utf8), categoryIDs: ids); return [] }
            catch let error as ToolArgumentError { return error.problems }
            catch { return ["\(error)"] }
        }
        #expect(problems("setCategoryTarget", #"{"categoryID":"dining"}"#) == ["$.monthlyAmount is required"])
        #expect(problems("setCategoryTarget", #"{"categoryID":"dining","monthlyAmount":500}"#).first?.contains("must be a string") == true)
        #expect(problems("setCategoryTarget", #"{"categoryID":"dining","monthlyAmount":"$500"}"#).first?.contains("must match") == true)
        #expect(problems("setCategoryTarget", #"{"categoryID":"dining","monthlyAmount":"500","note":"x"}"#) == ["$.note is not an allowed field"])
        #expect(problems("setCategoryTarget", #"{"categoryID":"pets","monthlyAmount":"5"}"#, ids: ["dining"]).first?.contains("must be one of") == true)
        #expect(problems("createBudgetRule", #"{"match":{},"categoryID":"dining","applyToExisting":true}"#) == ["$.match needs at least 1 field"])
        #expect(problems("updateDecisionPolicy", #"{"autoAcceptPercent":0.8}"#).contains { $0.contains("whole number") })
        #expect(problems("updateDecisionPolicy", #"{"autoAcceptPercent":120}"#).contains { $0.contains("≤ 99") })
        #expect(problems("projectBalance", #"{"account":"cash","horizonMonths":6,"goal":{"amount":"10","targetDate":"2026-02-30"}}"#).contains { $0.contains("date") })
        #expect(problems("sumByCategory", #"{"period":"Q3"}"#).first?.contains("must match") == true)
        #expect(problems("nope", "{}") == ["unknown tool"])
    }

    @Test("Category ids can be narrowed to the live list")
    func specialization() throws {
        let specs = ToolCatalog.specs(categoryIDs: ["dining", "groceries"])
        let rule = try #require(specs.first { $0.name == "createBudgetRule" })
        #expect(rule.schema.properties["categoryID"]?.enumValues == ["dining", "groceries"])
        let targets = try #require(ToolCatalog.specs(for: DemoLedger.categoryList).first { $0.name == "adjustCategoryTarget" })
        #expect(targets.schema.properties["categoryID"]?.enumValues?.contains("transfer") == false)
        #expect(ToolCatalog.specs(for: DemoLedger.categoryList).first { $0.name == "recategorize" }?.schema.properties["categoryID"]?.enumValues?.contains("transfer") == true)
        let tools = ToolCatalog.openAITools(for: DemoLedger.categoryList)
        guard case let .array(list) = tools, case let .object(first)? = list.first else { Issue.record("shape"); return }
        #expect(first["type"] == .string("function"))
    }

    @Test("Schema patterns avoid shorthand classes llama.cpp's grammar converter rejects")
    func grammarSafePatterns() {
        func patterns(_ v: JSONValue) -> [String] {
            switch v {
            case let .object(o):
                o.flatMap { key, value -> [String] in
                    if key == "pattern", case let .string(p) = value { return [p] }
                    return patterns(value)
                }
            case let .array(a): a.flatMap(patterns)
            default: []
            }
        }
        let found = patterns(ToolCatalog.openAITools(for: DemoLedger.categoryList))
        #expect(!found.isEmpty)
        for p in found { #expect(p.range(of: #"\\[dDwWsS]"#, options: .regularExpression) == nil, "\(p)") }
    }

    @Test("Decimal amounts parse strictly")
    func decimals() {
        #expect(DecimalAmount(string: "500")?.minorUnits == 50_000)
        #expect(DecimalAmount(string: "-25.5")?.minorUnits == -2_550)
        #expect(DecimalAmount(string: "+0.05")?.minorUnits == 5)
        #expect(DecimalAmount(string: "1,000") == nil)
        #expect(DecimalAmount(string: "$5") == nil)
        #expect(DecimalAmount(minorUnits: -2_550).description == "-25.50")
    }
}

@Suite("Assistant proposals")
struct ProposalTests {
    func ask(_ api: DemoBudgetAPI, _ q: String) async throws -> AskReply { try await api.ask(q, conversationID: nil) }

    @Test("Every tool call the demo emits validates against the catalog", arguments: [
        "What did we spend on dining in Q3 vs Q2?", "Can I set aside $5,000 by March?", "How much do subscriptions cost me?",
        "How is groceries doing?", "Where did my money go this month?", "Set the dining budget to $500",
        "Raise the groceries budget by $100", "Remove the shopping target", "Add a category for pets with a $100 target",
        "Always file Venmo as transfer", "Show me dining", "Turn on the decision model at 80%",
        "What is my DoorDash budget?", "Cap DoorDash at $150", "How much can I save?", "How much should I save?",
        "What's safe to spend this month?", "Set aside $1,200 a month",
    ])
    func toolCallsValidate(question: String) async throws {
        let reply = try await ask(Fixture.api(), question)
        #expect(!reply.toolCalls.isEmpty, "\(question)")
        for call in reply.toolCalls {
            #expect(throws: Never.self, "\(call.name) \(call.arguments)") {
                try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8), categoryIDs: DemoLedger.categoryList.map(\.id))
            }
        }
    }

    @Test("Proposals change nothing until applied")
    func proposalsAreInert() async throws {
        let api = Fixture.api()
        let reply = try await ask(api, "Set the dining budget to $500")
        let proposal = try #require(reply.proposedActions.first)
        #expect(proposal.action == .setCategoryTarget(SetCategoryTarget(categoryID: "dining", monthlyAmount: DecimalAmount(string: "500")!)))
        #expect(try await api.spending(.thisMonth).categories.first { $0.id == "dining" }?.target == Money(450))
        let result = try await api.perform(proposal.action)
        #expect(result.message.contains("$500"))
        #expect(try await api.spending(.thisMonth).categories.first { $0.id == "dining" }?.target == Money(500))
    }

    @Test("Relative changes are computed by the ledger, and previewed")
    func adjust() async throws {
        let api = Fixture.api()
        let reply = try await ask(api, "Raise the groceries budget by $100")
        let proposal = try #require(reply.proposedActions.first)
        #expect(proposal.action == .adjustCategoryTarget(AdjustCategoryTarget(categoryID: "groceries", change: DecimalAmount(string: "100")!)))
        #expect(proposal.effects.first { $0.id == "new" }?.value == Money(750))
        _ = try await api.perform(proposal.action)
        #expect(try await api.spending(.thisMonth).categories.first { $0.id == "groceries" }?.target == Money(750))
        await #expect(throws: BudgetAPIError.self) {
            try await api.perform(.adjustCategoryTarget(AdjustCategoryTarget(categoryID: "groceries", change: DecimalAmount(string: "-5000")!)))
        }
    }

    @Test("Rules re-file matching rows and clear them from review")
    func rule() async throws {
        let api = Fixture.api()
        let reply = try await ask(api, "Always file Venmo as transfer")
        let proposal = try #require(reply.proposedActions.first)
        guard case let .createBudgetRule(rule) = proposal.action else { Issue.record("wrong action"); return }
        #expect(rule.match.merchantContains == "venmo")
        #expect(rule.categoryID == "transfer")
        #expect(rule.createdBy == .assistant)
        #expect(!(reply.toolCalls.first?.arguments.contains("createdBy") ?? true)) // not something the model says
        let result = try await api.perform(proposal.action)
        #expect(result.affectedTransactions == 1)
        #expect(try await api.reviewQueue().count == 10)
        let venmo = try await api.transactions(TransactionFilter(search: "venmo"))
        // The demo already has three rules, so this one is the fourth — and the newest, listed first.
        #expect(venmo.allSatisfy { $0.categorization?.categoryID == "transfer" && $0.categorization?.ruleID == "rule-4" })
        let rules = try await api.rules()
        #expect(rules.first?.rule.createdBy == .assistant && rules.first?.hitCount == venmo.count)
        let listed = try await DemoToolbox(ledger: Setup.ledger(await api.state), decisions: nil).run(read: "findRules", arguments: .object([:])).result
        guard case let .object(o) = listed, case let .array(items)? = o["rules"], case let .object(first)? = items.first else { Issue.record("no rules"); return }
        #expect(first["id"] == .string("rule-4") && first["matches"] == .string("Merchant name contains “venmo”") && first["transactionsFiled"] == .number(1))
    }

    @Test("New categories show up everywhere, with their target")
    func newCategory() async throws {
        let api = Fixture.api()
        let proposal = try #require(try await ask(api, "Add a category for pets with a $100 target").proposedActions.first)
        #expect(proposal.action == .createCategory(CreateCategory(name: "Pets", symbol: "pawprint", monthlyTarget: DecimalAmount(string: "100")!)))
        _ = try await api.perform(proposal.action)
        #expect(try await api.categories().contains { $0.id == "pets" && $0.symbol == "pawprint" })
        #expect(try await api.spending(.thisMonth).categories.first { $0.id == "pets" }?.target == Money(100))
        await #expect(throws: BudgetAPIError.self) { try await api.perform(proposal.action) }
    }

    @Test("DoorDash: budget question answers with ledger figures; a cap is a proposal")
    func doordash() async throws {
        let api = Fixture.api()
        let answer = try await ask(api, "What is my DoorDash budget?")
        #expect(answer.toolCalls.first?.name == "sumByMerchant")
        #expect(answer.text.contains("DoorDash is at"))
        let cap = try #require(try await ask(api, "Cap DoorDash at $150").proposedActions.first)
        #expect(cap.action == .setMerchantTarget(SetMerchantTarget(merchant: "DoorDash", monthlyAmount: DecimalAmount(string: "150")!)))
        let save = try #require(try await ask(api, "Set aside $1,200 a month").proposedActions.first)
        #expect(save.action == .setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(string: "1200")!)))
        let goal = try await ask(api, "Can I set aside $5,000 by March?")
        #expect(goal.toolCalls.first?.name == "projectBalance") // a dated goal, not a monthly plan
    }

    @Test("Remove, navigate, and ambiguous requests")
    func others() async throws {
        let api = Fixture.api()
        let remove = try #require(try await ask(api, "Remove the shopping target").proposedActions.first)
        _ = try await api.perform(remove.action)
        #expect(try await api.spending(.thisMonth).categories.first { $0.id == "shopping" }?.target == nil)

        let nav = try #require(try await ask(api, "Show me dining").proposedActions.first)
        #expect(nav.action == .navigate(Navigate(screen: .spending, categoryID: "dining")))
        await #expect(throws: BudgetAPIError.self) { try await api.perform(nav.action) }

        let vague = try await ask(api, "Change the dining budget")
        #expect(vague.proposedActions.isEmpty)
        #expect(vague.text.hasSuffix("?"))
    }
}

@Suite("Grounding")
struct GroundingTests {
    @Test("Flags amounts that don't come from tools")
    func amounts() {
        let allowed = [Money(647.80), Money(1802.8)]
        #expect(Grounding.ungroundedAmounts(in: "You spent $647.80, versus $1,802.80.", allowed: allowed).isEmpty)
        #expect(Grounding.ungroundedAmounts(in: "About $648 so far.", allowed: allowed).isEmpty)
        #expect(Grounding.ungroundedAmounts(in: "That's $2,450.60 combined.", allowed: allowed) == ["$2,450.60"])
        #expect(Grounding.ungroundedAmounts(in: "Roughly $650.", allowed: allowed) == ["$650"])
    }

    @Test("Flags percentages that don't come from tools")
    func percents() {
        #expect(Grounding.ungroundedPercents(in: "24% more than Q2", allowed: [24]).isEmpty)
        #expect(Grounding.ungroundedPercents(in: "about 25 % more", allowed: [24]) == ["25 %"])
    }

    @Test("Demo replies are grounded in their own figures", arguments: [
        "What did we spend on dining in Q3 vs Q2?", "Can I set aside $5,000 by March?", "How much do subscriptions cost me?",
        "How is groceries doing?", "Where did my money go this month?", "What is my DoorDash budget?",
        "How much can I save?", "How much should I save?", "What's safe to spend this month?",
    ])
    func demoGrounded(question: String) async throws {
        let reply = try await Fixture.api().ask(question, conversationID: nil)
        let ledger = Fixture.ledger()
        let allowed = reply.figures.map(\.value) + Array(ledger.monthlyTargets.values)
            + [ledger.guidance().savingNow, ledger.flexBudget().plannedSavings, ledger.flexBudget().flexNumber]
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: allowed).isEmpty, "\(reply.text)")
    }
}

@Suite("System prompt")
struct PromptTests {
    @Test("Renders today's date, the categories and targets, and no placeholders")
    func renders() async throws {
        let config = try await Fixture.api().assistantConfig()
        let prompt = config.systemPrompt
        #expect(prompt.contains("Friday, September 25, 2026"))
        #expect(prompt.contains("2026-Q3"))
        #expect(prompt.contains("- dining — Dining — monthly target $450.00"))
        #expect(prompt.contains("- transfer — Transfer — not spending"))
        #expect(prompt.contains("adjustCategoryTarget"))
        #expect(!prompt.contains("\\("))
        #expect(config.tools.count == ToolCatalog.specs.count)
    }
}
