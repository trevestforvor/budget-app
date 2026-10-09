import Foundation

/// This month's pace against what the person set: the everyday budget, category targets and merchant caps. Each
/// alert is one target past one threshold — 80% used, or on pace to finish over — worked out by the ledger
/// (`Ledger.paceAlerts`). The server pushes each one at most once a month (`PaceAlertSender`); the app lists them.
public struct PaceAlerts: Codable, Hashable, Sendable {
    /// The budget month, "2026-10", in the ledger's calendar.
    public var month: String
    /// Today's day of the month, and how many days it has.
    public var day: Int
    public var daysInMonth: Int
    /// Whether the month is far enough in (the second week on) for a projection to mean anything. Before it, only
    /// what's already been spent can raise an alert.
    public var projecting: Bool
    /// The everyday budget's pace, alerting or not; nil without an everyday budget (no income to budget from yet).
    public var everyday: PaceStatus?
    /// Everything past a threshold right now, most pressing first.
    public var alerts: [PaceAlert]

    public init(month: String, day: Int, daysInMonth: Int, projecting: Bool, everyday: PaceStatus?, alerts: [PaceAlert]) {
        self.month = month
        self.day = day
        self.daysInMonth = daysInMonth
        self.projecting = projecting
        self.everyday = everyday
        self.alerts = alerts
    }

    /// The day projections start: the first of the month's second week.
    public static let firstProjectingDay = 8
}

/// One target's month so far.
public struct PaceStatus: Codable, Hashable, Sendable {
    public var spent: Money
    /// The everyday budget, the category's target, or the merchant's cap.
    public var limit: Money
    /// Where the month lands at the pace so far (spent ÷ days gone × days in the month); nil before the second week.
    public var projected: Money?
    /// What each day left (today included) can take and still finish on budget; nil once nothing is left.
    public var perDayLeft: Money?
    /// Spent as a share of the limit, rounded.
    public var usedPercent: Int

    public init(spent: Money, limit: Money, projected: Money?, perDayLeft: Money?, usedPercent: Int) {
        self.spent = spent
        self.limit = limit
        self.projected = projected
        self.perDayLeft = perDayLeft
        self.usedPercent = usedPercent
    }

    /// How far past the limit the projection lands; nil when it doesn't.
    public var projectedOver: Money? {
        guard let projected, projected > limit else { return nil }
        return projected - limit
    }

    /// How far past the limit spending already is; nil when it isn't.
    public var over: Money? { spent > limit ? spent - limit : nil }
}

public struct PaceAlert: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The everyday budget (safe to spend's month).
        case everyday
        /// A category's monthly target.
        case category
        /// A merchant's monthly cap.
        case merchant
        /// A kind a later server sends: shown, never acted on.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Threshold: String, Codable, Sendable, CaseIterable {
        /// 80% of a target or cap is gone.
        case used80
        /// At the pace so far the month finishes over (or already has).
        case projectedOver
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Threshold(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// Projected over says more than 80% used: when both are new, it's the one that's sent.
        public var rank: Int {
            switch self {
            case .used80: 1
            case .projectedOver: 2
            case .unknown: 0
            }
        }
    }

    public var kind: Kind
    public var threshold: Threshold
    /// "everyday", the category's id, or the merchant's name.
    public var targetID: String
    /// "Everyday", "Dining", "DoorDash".
    public var name: String
    public var status: PaceStatus
    /// The notification's title and body, amounts written out.
    public var title: String
    public var body: String
    /// The screen a tap opens.
    public var link: Checkup.Link

    /// "category:dining:used80" — what the server records as sent, with the month.
    public var id: String { "\(targetKey):\(threshold.rawValue)" }
    /// "category:dining" — one target, whatever the threshold.
    public var targetKey: String { "\(kind.rawValue):\(targetID)" }

    public init(kind: Kind, threshold: Threshold, targetID: String, name: String, status: PaceStatus, title: String, body: String, link: Checkup.Link) {
        self.kind = kind
        self.threshold = threshold
        self.targetID = targetID
        self.name = name
        self.status = status
        self.title = title
        self.body = body
        self.link = link
    }
}

/// Which pace alerts one phone wants. Nil on a device means none: a phone hears about pace only once its app has
/// asked (an app before them has no switch to turn them off).
public struct PaceAlertPreferences: Codable, Hashable, Sendable {
    /// The everyday budget on pace to finish over. On unless turned off.
    public var everyday: Bool
    /// Category targets at 80% or on pace to finish over. Off unless turned on.
    public var categories: Bool
    /// Merchant caps at 80% or on pace to finish over. Off unless turned on.
    public var merchants: Bool

    public init(everyday: Bool = true, categories: Bool = false, merchants: Bool = false) {
        self.everyday = everyday
        self.categories = categories
        self.merchants = merchants
    }

    public static let defaults = PaceAlertPreferences()

    /// Whether any kind is on.
    public var any: Bool { everyday || categories || merchants }

    public func wants(_ kind: PaceAlert.Kind) -> Bool {
        switch kind {
        case .everyday: everyday
        case .category: categories
        case .merchant: merchants
        case .unknown: false
        }
    }

    enum CodingKeys: String, CodingKey { case everyday, categories, merchants }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        everyday = try c.decodeIfPresent(Bool.self, forKey: .everyday) ?? true
        categories = try c.decodeIfPresent(Bool.self, forKey: .categories) ?? false
        merchants = try c.decodeIfPresent(Bool.self, forKey: .merchants) ?? false
    }
}

/// Pace alerts, on clients that talk to a ledger: the server and the demo. Apart from `BudgetAPI` so a client that
/// doesn't have them needs nothing.
public protocol PaceAlertsAPI: Sendable {
    /// This month's pace and what's past a threshold now (`GET /v1/alerts/pace`).
    func paceAlerts() async throws -> PaceAlerts
}

extension ServerStatus {
    /// The first server that sends pace alerts, keeps a phone's choice of them (`DeviceRegistration.paceAlerts`) and
    /// answers `GET /v1/alerts/pace`. An older one drops the choice without a word.
    public static let paceAlertsSince = "0.5.0"
}

extension LedgerBudgetAPI: PaceAlertsAPI {}
