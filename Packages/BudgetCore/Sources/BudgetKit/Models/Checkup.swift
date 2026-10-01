import Foundation

/// A full pass over the ledger in one call: every figure comes from the ledger, and every finding says
/// whether it's fine, worth watching, or worth acting on. The assistant narrates it; it never computes it.
public struct Checkup: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable, Comparable {
        case good, watch, act
        public static func < (a: Status, b: Status) -> Bool { a.rank < b.rank }
        var rank: Int { switch self { case .good: 0; case .watch: 1; case .act: 2 } }
    }

    /// The screen a finding, or one figure in it, is about, for the app to open on a tap. On the wire
    /// `{"to": "category", "id": "dining"}`; a destination this build doesn't know reads as `.unknown` (nothing opens)
    /// rather than failing the checkup.
    public enum Link: Hashable, Sendable {
        /// What's waiting for review.
        case review
        /// This month's budget.
        case budget
        /// One category's month.
        case category(String)
        /// A merchant's charges.
        case merchant(String)
        /// One transaction.
        case transaction(String)
        /// Subscriptions and bills.
        case recurring
        /// The forecast and savings.
        case plan
        /// Linked accounts and connections.
        case accounts
        case unknown
    }

    public struct Metric: Hashable, Codable, Sendable {
        public var label: String
        public var money: Money?
        public var text: String?
        public var link: Link?
        public init(_ label: String, money: Money, link: Link? = nil) { self.label = label; self.money = money; self.link = link }
        public init(_ label: String, text: String) { self.label = label; self.text = text }
    }

    public struct Finding: Identifiable, Hashable, Codable, Sendable {
        public var id: String
        public var status: Status
        public var title: String
        public var detail: String?
        public var metrics: [Metric]
        /// A question or instruction for Ask that acts on this finding (e.g. "Cap DoorDash at $150 a month").
        public var suggestion: String?
        /// Where tapping it goes. Nil from servers before 0.3.2, and for a finding with nowhere better to go.
        public var link: Link? = nil
    }

    public struct Section: Identifiable, Hashable, Codable, Sendable {
        public var id: String
        public var title: String
        public var symbol: String
        public var findings: [Finding]
        public var status: Status { findings.map(\.status).max() ?? .good }
    }

    public var asOf: Date
    public var headline: String
    public var sections: [Section]

    public var counts: (act: Int, watch: Int, good: Int) {
        let all = sections.flatMap(\.findings)
        return (all.filter { $0.status == .act }.count, all.filter { $0.status == .watch }.count, all.filter { $0.status == .good }.count)
    }
}

extension Checkup.Link: Codable {
    private enum CodingKeys: String, CodingKey { case to, id }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(String.self, forKey: .id)
        switch (try container.decode(String.self, forKey: .to), id) {
        case ("review", _): self = .review
        case ("budget", _): self = .budget
        case let ("category", id?): self = .category(id)
        case let ("merchant", id?): self = .merchant(id)
        case let ("transaction", id?): self = .transaction(id)
        case ("recurring", _): self = .recurring
        case ("plan", _): self = .plan
        case ("accounts", _): self = .accounts
        default: self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let (to, id): (String, String?) = switch self {
        case .review: ("review", nil)
        case .budget: ("budget", nil)
        case let .category(id): ("category", id)
        case let .merchant(name): ("merchant", name)
        case let .transaction(id): ("transaction", id)
        case .recurring: ("recurring", nil)
        case .plan: ("plan", nil)
        case .accounts: ("accounts", nil)
        case .unknown: ("unknown", nil)
        }
        try container.encode(to, forKey: .to)
        try container.encodeIfPresent(id, forKey: .id)
    }
}
