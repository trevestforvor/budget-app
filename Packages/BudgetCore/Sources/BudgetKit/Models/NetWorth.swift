import Foundation

// MARK: - Net worth over time (server 0.5.0)

/// The span the net worth history covers: `GET /v1/networth?range=`.
public enum NetWorthRange: String, Hashable, Sendable, Codable, CaseIterable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case yearToDate = "YTD"
    case oneYear = "1Y"
    case all = "ALL"

    /// "1M", "YTD": the segment title.
    public var label: String { rawValue }

    /// "the last month", "this year": for sentences.
    public var phrase: String {
        switch self {
        case .oneMonth: "the last month"
        case .threeMonths: "the last three months"
        case .yearToDate: "this year"
        case .oneYear: "the last year"
        case .all: "everything the ledger holds"
        }
    }
}

/// One account's balance at the end of a day, recorded when a sync brings it in. History before an account's first
/// snapshot is worked out from its transactions (cash and cards) or held at its first known value (investments).
/// Snapshots grow every day, so they live in their own store (`BalanceHistoryStore`), never in `LedgerState`.
public struct BalanceSnapshot: Hashable, Codable, Sendable {
    public var accountID: String
    /// "2026-09-28": a day in the ledger's calendar. One per account per day; a later sync that day replaces it.
    public var day: String
    /// The balance as the ledger holds it: cards are negative while money is owed.
    public var balance: Money

    public init(accountID: String, day: String, balance: Money) {
        self.accountID = accountID
        self.day = day
        self.balance = balance
    }
}

/// Where balance snapshots are kept. The server's is a Postgres table; the demo and tests keep them in memory.
public protocol BalanceHistoryStore: Sendable {
    /// Every snapshot, in no particular order.
    func balanceSnapshots() async throws -> [BalanceSnapshot]
    /// Adds each snapshot, replacing one for the same account and day.
    func saveBalanceSnapshots(_ snapshots: [BalanceSnapshot]) async throws
    func clearBalanceSnapshots() async throws
}

/// Snapshots in memory: the demo, tests, and a server without Postgres.
public actor MemoryBalanceHistory: BalanceHistoryStore {
    private var table: [String: BalanceSnapshot] = [:]

    public init(_ snapshots: [BalanceSnapshot] = []) {
        for snapshot in snapshots { table[Self.key(snapshot)] = snapshot }
    }

    private static func key(_ s: BalanceSnapshot) -> String { "\(s.accountID)\u{1F}\(s.day)" }

    public func balanceSnapshots() async throws -> [BalanceSnapshot] { Array(table.values) }

    public func saveBalanceSnapshots(_ snapshots: [BalanceSnapshot]) async throws {
        for snapshot in snapshots { table[Self.key(snapshot)] = snapshot }
    }

    public func clearBalanceSnapshots() async throws { table = [:] }
}

// MARK: - Manual assets and debts

/// Something you own, or owe, that no bank link reports.
public enum ManualAssetKind: String, Hashable, Sendable, Codable, CaseIterable {
    case asset, liability

    public var label: String { self == .asset ? "Asset" : "Debt" }

    /// A kind a newer server adds reads as an asset rather than failing the whole response.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .asset
    }
}

public enum ManualAssetCategory: String, Hashable, Sendable, Codable, CaseIterable {
    case realEstate, vehicle, loan, other

    public var label: String {
        switch self {
        case .realEstate: "Real estate"
        case .vehicle: "Vehicle"
        case .loan: "Loan"
        case .other: "Other"
        }
    }

    /// An SF Symbol name for the app.
    public var symbol: String {
        switch self {
        case .realEstate: "house"
        case .vehicle: "car"
        case .loan: "banknote"
        case .other: "shippingbox"
        }
    }

    /// A category a newer server adds reads as "other".
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// A value an asset or debt had from `date` on.
public struct ManualAssetValue: Hashable, Codable, Sendable {
    public var date: Date
    public var value: Money

    public init(date: Date, value: Money) {
        self.date = date
        self.value = value
    }
}

/// A home, a car, a loan: kept by hand, counted in net worth from the day it was added, at each value it was given.
public struct ManualAsset: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: ManualAssetKind
    public var category: ManualAssetCategory
    /// What it's worth now; for a debt, what's owed. Never negative.
    public var value: Money
    public var updatedAt: Date
    public var createdAt: Date?
    /// Every value it was given, oldest first (one a day: a second change the same day replaces the first).
    public var history: [ManualAssetValue]?

    public init(id: String, name: String, kind: ManualAssetKind, category: ManualAssetCategory, value: Money, updatedAt: Date,
                createdAt: Date? = nil, history: [ManualAssetValue]? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.value = value
        self.updatedAt = updatedAt; self.createdAt = createdAt; self.history = history
    }

    public var isLiability: Bool { kind == .liability }
}

// MARK: - The net worth response

/// Where a line sits in the assets and debts lists, in display order.
public enum NetWorthGroup: String, Hashable, Sendable, Codable, CaseIterable {
    case cash, investments, realEstate, vehicles, otherAssets
    case cards, loans, otherDebts

    public var label: String {
        switch self {
        case .cash: "Cash"
        case .investments: "Investments"
        case .realEstate: "Real estate"
        case .vehicles: "Vehicles"
        case .otherAssets: "Other assets"
        case .cards: "Credit cards"
        case .loans: "Loans"
        case .otherDebts: "Other debts"
        }
    }

    public var isLiability: Bool { [.cards, .loans, .otherDebts].contains(self) }

    /// A group a newer server adds lands with other assets rather than failing the response.
    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .otherAssets
    }
}

/// One account or hand-kept item in the breakdown.
public struct NetWorthLine: Identifiable, Hashable, Codable, Sendable {
    /// The account id, or the manual item's id.
    public var id: String
    public var name: String
    /// The institution, or the item's category.
    public var detail: String?
    public var group: NetWorthGroup
    /// What it's worth now; for a debt, what's owed (positive while owed).
    public var value: Money
    /// Since the range began: more owed is a positive change on a debt.
    public var change: Money?
    /// Kept by hand (`ManualAsset`), so it can be edited.
    public var isManual: Bool?
    /// Part of its history is a stand-in: an investment before its first recorded balance.
    public var isEstimated: Bool?

    public init(id: String, name: String, detail: String? = nil, group: NetWorthGroup, value: Money, change: Money? = nil,
                isManual: Bool? = nil, isEstimated: Bool? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.group = group; self.value = value; self.change = change
        self.isManual = isManual; self.isEstimated = isEstimated
    }
}

/// Net worth at the end of one day.
public struct NetWorthPoint: Hashable, Codable, Sendable {
    /// Start of the day in the ledger's time zone.
    public var date: Date
    public var netWorth: Money
    public var assets: Money
    public var liabilities: Money
    /// Holds an investment at a stand-in value (before its first recorded balance).
    public var isEstimated: Bool?

    public init(date: Date, netWorth: Money, assets: Money, liabilities: Money, isEstimated: Bool? = nil) {
        self.date = date; self.netWorth = netWorth; self.assets = assets; self.liabilities = liabilities; self.isEstimated = isEstimated
    }
}

/// `GET /v1/networth`: what you own less what you owe, over a range, with the breakdown behind today's figure.
public struct NetWorth: Hashable, Codable, Sendable {
    /// The range asked for ("3M").
    public var range: String
    public var asOf: Date
    /// The first day shown: the range's start, or the ledger's first day when it holds less.
    public var start: Date
    /// Oldest first, today last; daily for short ranges, thinned for long ones.
    public var points: [NetWorthPoint]
    /// Today: equals `Balances.netWorth`.
    public var netWorth: Money
    public var assets: Money
    public var liabilities: Money
    /// Today less the first point.
    public var change: Money
    /// `change` as a percent of the first point; nil when that wasn't above zero.
    public var changePercent: Double?
    public var assetLines: [NetWorthLine]
    public var liabilityLines: [NetWorthLine]
    /// The hand-kept items, for editing.
    public var manualAssets: [ManualAsset]
    /// The last day whose figure holds an investment at a stand-in value; nil when every point is from records.
    public var estimatedThrough: Date?
    /// A plain sentence about what's estimated, when something is.
    public var note: String?

    public init(range: String, asOf: Date, start: Date, points: [NetWorthPoint], netWorth: Money, assets: Money, liabilities: Money,
                change: Money, changePercent: Double?, assetLines: [NetWorthLine], liabilityLines: [NetWorthLine],
                manualAssets: [ManualAsset], estimatedThrough: Date? = nil, note: String? = nil) {
        self.range = range; self.asOf = asOf; self.start = start; self.points = points; self.netWorth = netWorth; self.assets = assets
        self.liabilities = liabilities; self.change = change; self.changePercent = changePercent; self.assetLines = assetLines
        self.liabilityLines = liabilityLines; self.manualAssets = manualAssets; self.estimatedThrough = estimatedThrough; self.note = note
    }
}

/// Net worth reads. A side protocol (like `MorningSummaryAPI`) so the five `BudgetAPI` conformers don't all need it;
/// writes go through `perform` (`saveManualAsset`, `removeManualAsset`).
public protocol NetWorthAPI: Sendable {
    func netWorth(range: NetWorthRange) async throws -> NetWorth
}

extension ServerStatus {
    /// The first server with net worth history and hand-kept assets and debts (`GET /v1/networth`, `saveManualAsset`).
    public static let netWorthSince = "0.5.0"
}

// MARK: - Actions

/// Adds a hand-kept asset or debt (no `id`), or changes one. Only the fields given change; a new value is recorded in
/// its history from today. `{"type": "saveManualAsset", ...}`; not an assistant tool.
public struct SaveManualAsset: Hashable, Sendable, Codable {
    /// Nil adds a new one.
    public var id: String?
    public var name: String?
    public var kind: ManualAssetKind?
    public var category: ManualAssetCategory?
    /// What it's worth now, or what's owed on a debt.
    public var value: DecimalAmount?
    /// Undo only: puts the item back exactly as it was, history included.
    public var restore: ManualAsset?

    public init(id: String? = nil, name: String? = nil, kind: ManualAssetKind? = nil, category: ManualAssetCategory? = nil,
                value: DecimalAmount? = nil, restore: ManualAsset? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.category = category; self.value = value; self.restore = restore
    }
}

/// Removes a hand-kept asset or debt from net worth, its history too. `{"type": "removeManualAsset", "id": …}`.
public struct RemoveManualAsset: Hashable, Sendable, Codable {
    public var id: String
    public init(id: String) { self.id = id }
}
