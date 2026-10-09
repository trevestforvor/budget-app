import Foundation

/// One month's money as a flow, left to right: where it came from (each income source, and cash drawn down when
/// spending passed income), the budget's three buckets and what was left (Saved), then each bucket's top categories.
/// Every node's inflow equals its outflow, to the cent.
public struct CashFlowSankey: Hashable, Codable, Sendable {
    public struct Node: Identifiable, Hashable, Codable, Sendable {
        public enum Kind: String, Hashable, Sendable, Codable {
            /// An income source: a payer, or a money-in category with no payer to name.
            case income
            /// Spending past income, paid from cash on hand.
            case drawn
            /// Bills, Subscriptions or Everyday.
            case bucket
            /// Income left after spending.
            case saved
            /// A spending category within a bucket.
            case category
            /// A bucket's smaller categories, or the smaller income sources, together.
            case other

            /// A kind added by a later version reads as `other`.
            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
            }
        }

        public var id: String
        public var label: String
        public var kind: Kind
        /// 0 sources, 1 buckets and Saved, 2 categories.
        public var column: Int
        public var value: Money
        /// The bucket a bucket, category or "other" node belongs to.
        public var group: CategoryGroup?
        public var categoryID: String?
        /// A design-system tone name (`CategoryColor`), or nil for a neutral node.
        public var color: String?

        public init(id: String, label: String, kind: Kind, column: Int, value: Money, group: CategoryGroup? = nil,
                    categoryID: String? = nil, color: String? = nil) {
            self.id = id; self.label = label; self.kind = kind; self.column = column; self.value = value
            self.group = group; self.categoryID = categoryID; self.color = color
        }
    }

    public struct Link: Hashable, Codable, Sendable {
        public var source: String
        public var target: String
        public var value: Money

        public init(source: String, target: String, value: Money) {
            self.source = source; self.target = target; self.value = value
        }
    }

    /// "2026-09".
    public var month: String
    /// This month, still under way.
    public var isPartial: Bool
    /// Money filed under money-in categories.
    public var income: Money
    /// Spending as the budget counts it: every category net of its refunds, a charge spread over the year at a twelfth.
    public var spending: Money
    /// Income less spending, when that's above zero.
    public var saved: Money
    /// Spending less income, when spending was higher.
    public var drawnFromCash: Money
    /// By column, then as drawn top to bottom.
    public var nodes: [Node]
    public var links: [Link]

    public init(month: String, isPartial: Bool, income: Money, spending: Money, saved: Money, drawnFromCash: Money, nodes: [Node], links: [Link]) {
        self.month = month; self.isPartial = isPartial; self.income = income; self.spending = spending; self.saved = saved
        self.drawnFromCash = drawnFromCash; self.nodes = nodes; self.links = links
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// What flows into a node from the column before it.
    public func inflow(_ id: String) -> Money { links.filter { $0.target == id }.map(\.value).sum() }
    /// What flows out of a node to the column after it.
    public func outflow(_ id: String) -> Money { links.filter { $0.source == id }.map(\.value).sum() }
}

/// The month's cash flow as a Sankey, on clients that talk to a ledger.
public protocol CashFlowSankeyAPI: Sendable {
    /// `month` is "2026-09"; nil is this month so far.
    func cashFlowSankey(month: String?) async throws -> CashFlowSankey
}
