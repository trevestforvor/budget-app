import Foundation

/// What the agent loop can do against a ledger. The server implements it over Postgres;
/// `DemoToolbox` implements it over the demo ledger.
public protocol AgentToolbox: Sendable {
    var categories: [BudgetCategory] { get }
    var assistantContext: AssistantContext { get }
    /// Runs a read tool. Returns the result the model sees and the figures the app shows.
    func run(read tool: String, arguments: JSONValue) async throws -> (result: JSONValue, figures: [Figure])
    /// Turns a write or client call into a proposal with ledger-computed effects. Changes nothing.
    func propose(_ action: AppAction) async throws -> ProposedAction
}

public struct AgentOutcome: Sendable {
    public var reply: AskReply
    /// Figures in the final text that no tool returned, after one repair attempt.
    public var ungrounded: [String]
    public var steps: Int
    /// Tool calls rejected by schema validation and sent back for repair.
    public var repairs: Int
    public var transcript: [ChatMessage]
}

public enum AgentError: LocalizedError {
    case tooManySteps(Int)
    /// The reply stopped at the token limit before any answer came out, which reasoning models do when their thinking
    /// uses the whole budget.
    case ranOutOfTokens
    public var errorDescription: String? {
        switch self {
        case let .tooManySteps(n): "The assistant didn't finish within \(n) steps."
        case .ranOutOfTokens: "The model used its whole token budget before it answered. A reasoning model may need less reasoning or a larger limit."
        }
    }
}

/// The agent loop the intent describes: the model interprets and calls tools, the ledger computes,
/// write tools become proposals, arguments are schema-checked, and the final prose is grounded.
public struct AgentLoop: Sendable {
    public var model: any ChatModel
    public var toolbox: any AgentToolbox
    public var thinking: Bool
    public var maxSteps: Int

    public init(model: any ChatModel, toolbox: any AgentToolbox, thinking: Bool = false, maxSteps: Int = 8) {
        self.model = model
        self.toolbox = toolbox
        self.thinking = thinking
        self.maxSteps = maxSteps
    }

    public func run(_ question: String, conversationID: String = UUID().uuidString, history: [ChatMessage] = []) async throws -> AgentOutcome {
        let categories = toolbox.categories
        let ids = categories.map(\.id)
        let spendingIDs = categories.filter(\.countsAsSpending).map(\.id)
        let mergeableIDs = categories.filter { $0.countsAsSpending || $0.isMoneyIn }.map(\.id)
        let tools = ToolCatalog.openAITools(for: categories)
        let prompt = AssistantPrompt.system(toolbox.assistantContext)

        var messages: [ChatMessage] = [.system(prompt)] + history + [.user(question)]
        var calls: [ToolCall] = []
        var proposals: [ProposedAction] = []
        var figures: [Figure] = []
        // Everything the model may quote: tool results plus the prompt's category list.
        var groundingText = prompt + "\n" + question
        var repairs = 0
        var groundingRetried = false

        for step in 1...maxSteps {
            let response = try await model.complete(ChatRequest(messages: messages, tools: tools, thinking: thinking))
            let message = response.message

            if !message.toolCalls.isEmpty {
                messages.append(message)
                for call in message.toolCalls {
                    let result: JSONValue
                    do {
                        let arguments = try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8),
                                                                           categoryIDs: ids, spendingCategoryIDs: spendingIDs, mergeableCategoryIDs: mergeableIDs)
                        calls.append(ToolCall(id: call.id, name: call.name, arguments: call.arguments))
                        switch ToolCatalog.spec(named: call.name)?.kind {
                        case .read?:
                            let output = try await toolbox.run(read: call.name, arguments: arguments)
                            figures += output.figures
                            result = output.result
                        default:
                            let action = try AppAction(toolName: call.name, arguments: Data(call.arguments.utf8))
                            let proposal = try await toolbox.propose(action)
                            proposals.append(proposal)
                            result = .object([
                                "status": .string("proposed — shown to the user as a card; nothing changes unless they tap Apply"),
                                "title": .string(proposal.title),
                                "effects": .array(proposal.effects.map { .object(["label": .string($0.label), "value": .string($0.value.display)]) }),
                            ])
                        }
                    } catch let error as ToolArgumentError {
                        repairs += 1
                        result = .object(["error": .string("invalid arguments"), "problems": .array(error.problems.map(JSONValue.string)),
                                          "fix": .string("Call \(call.name) again with arguments that satisfy its schema.")])
                    } catch {
                        result = .object(["error": .string(error.localizedDescription)])
                    }
                    let text = (try? result.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    groundingText += "\n" + text
                    messages.append(.tool(call.id, text))
                }
                continue
            }

            let text = message.content ?? ""
            if text.isEmpty, response.finishReason == "length" { throw AgentError.ranOutOfTokens }
            let allowedAmounts = Grounding.amounts(in: groundingText)
            let allowedPercents = Grounding.percents(in: groundingText)
            let ungrounded = Grounding.ungroundedAmounts(in: text, allowed: allowedAmounts)
                + Grounding.ungroundedPercents(in: text, allowed: allowedPercents)
            if !ungrounded.isEmpty, !groundingRetried {
                groundingRetried = true
                messages.append(message)
                messages.append(.user("[system check] These figures in your reply don't appear in any tool result: \(ungrounded.joined(separator: ", ")). Rewrite the reply using only figures the tools returned, or call a tool that computes what you need."))
                continue
            }
            let reply = AskReply(id: UUID().uuidString, conversationID: conversationID, text: text, figures: figures,
                                 toolCalls: calls, model: model.label, followUps: [], proposedActions: proposals)
            return AgentOutcome(reply: reply, ungrounded: ungrounded, steps: step, repairs: repairs, transcript: messages + [message])
        }
        throw AgentError.tooManySteps(maxSteps)
    }
}

extension Money {
    /// "$1,234.56" / "−$1,234.56" in en_US — the one format tools use, so grounding can match it.
    public var display: String { formatted(locale: Locale(identifier: "en_US")) }
}

extension Grounding {
    /// Every currency amount in `text` (tool results), for use as the allowed set.
    public static func amounts(in text: String) -> [Money] {
        text.matches(of: /\$\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?/).compactMap { m in
            guard let whole = Int64(m.1.replacingOccurrences(of: ",", with: "")) else { return nil }
            let cents = m.2.map { Int64($0.padding(toLength: 2, withPad: "0", startingAt: 0))! } ?? 0
            return Money(minorUnits: whole * 100 + cents)
        }
    }

    public static func percents(in text: String) -> [Int] {
        text.matches(of: /(\d{1,4})\s?%/).compactMap { Int($0.1) }
    }
}
