import Foundation

/// What an app can take back from Ask, declared with each question (`capabilities` in the ask body, 0.5.0+).
///
/// An app before 0.5.0 declares nothing, and a server before 0.5.0 ignores the field, so both directions keep working:
/// a new server leaves out what an old app can't decode (a `rememberFact` card fails its whole reply) or would silently
/// drop when it sends the action back (`fileSimilar`, `addTags`, `removeTags` on `editTransactions`: Apply would do less
/// than the card said).
public struct AskCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `rememberFact` proposals: assistant memory.
    public static let rememberFact = AskCapabilities(rawValue: 1 << 0)
    /// `editTransactions` with `fileSimilar`, `addTags` or `removeTags`.
    public static let transactionTools = AskCapabilities(rawValue: 1 << 1)

    /// Everything this build understands: what an app sends, and what the in-process demo assumes.
    public static let all: AskCapabilities = [.rememberFact, .transactionTools]
    /// An app that declared nothing: one from before 0.5.0.
    public static let legacy: AskCapabilities = []

    static let named: [(String, AskCapabilities)] = [("rememberFact", .rememberFact), ("transactionTools", .transactionTools)]

    /// The names an app sends. Unknown names (from a later app) are ignored; none at all is `legacy`.
    public init(names: [String]?) {
        self = []
        for name in names ?? [] { if let found = Self.named.first(where: { $0.0 == name }) { insert(found.1) } }
    }

    public var names: [String] { Self.named.filter { contains($0.1) }.map(\.0) }

    /// Whether an app with these capabilities can show and apply `action` as proposed.
    public func allows(_ action: AppAction) -> Bool {
        switch action {
        case .rememberFact: return contains(.rememberFact)
        case let .editTransactions(edit):
            return contains(.transactionTools) || (edit.fileSimilar == nil && edit.addTags == nil && edit.removeTags == nil)
        default: return true
        }
    }
}

extension ToolCatalog {
    /// The editTransactions fields an app needs `transactionTools` for.
    static let transactionToolFields = ["fileSimilar", "addTags", "removeTags"]

    /// `specs` without what `capabilities` can't take: no `rememberFact` tool, and editTransactions without its 0.5.0
    /// fields.
    static func specs(_ specs: [ToolSpec], for capabilities: AskCapabilities) -> [ToolSpec] {
        specs.compactMap { spec in
            if spec.name == "rememberFact", !capabilities.contains(.rememberFact) { return nil }
            if spec.name == "editTransactions", !capabilities.contains(.transactionTools) {
                return ToolSpec(name: spec.name, description: "Propose changes to specific transactions: file them under a category, keep the category they already have, hide them from spending and budget totals (or count them again), mark a yearly charge to spread it over the year (or not), add a note, or rename the merchant. Give only the fields to change.",
                                kind: spec.kind, schema: spec.schema.removingProperties(Set(transactionToolFields)))
            }
            return spec
        }
    }
}
