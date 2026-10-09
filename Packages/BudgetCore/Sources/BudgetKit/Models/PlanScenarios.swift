import Foundation

/// A change the person expects, for a "what if" on Plan: a car payment from March, a bonus in December, rent up $200
/// from June. One-time or recurring, money in or money out, in whole months.
public struct PlanEvent: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {
        case income, expense

        /// A kind added by a later version reads as an expense, the cautious side.
        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .expense
        }
    }

    public enum Cadence: String, CaseIterable, Hashable, Sendable, Codable {
        /// Once, in `startMonth`.
        case once
        case monthly
        /// In `startMonth` and every twelve months after it.
        case yearly

        /// A cadence added by a later version reads as one-time.
        public init(from decoder: any Decoder) throws {
            self = Cadence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .once
        }

        public var label: String {
            switch self {
            case .once: "Once"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Always positive; `kind` says which way it goes.
    public var amount: Money
    /// The month it starts (or happens, for `once`), like "2027-03".
    public var startMonth: String
    /// The last month it happens, inclusive; nil runs on. Ignored for `once`.
    public var endMonth: String?
    public var cadence: Cadence
    /// Off: kept in the scenario, left out of its projection.
    public var isEnabled: Bool

    public init(id: String, name: String, kind: Kind, amount: Money, startMonth: String, endMonth: String? = nil,
                cadence: Cadence, isEnabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.amount = amount; self.startMonth = startMonth
        self.endMonth = endMonth; self.cadence = cadence; self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, amount, startMonth, endMonth, cadence, isEnabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  kind: try c.decode(Kind.self, forKey: .kind), amount: try c.decode(Money.self, forKey: .amount),
                  startMonth: try c.decode(String.self, forKey: .startMonth), endMonth: try c.decodeIfPresent(String.self, forKey: .endMonth),
                  cadence: try c.decodeIfPresent(Cadence.self, forKey: .cadence) ?? .once,
                  isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true)
    }

    /// The signed change to cash each time it happens.
    public var signedAmount: Money { kind == .income ? amount : -amount }

    /// "$450 a month from March 2027", "$5,000 in December 2026", "$1,200 a year from June 2027 to June 2029".
    public func summary(calendar: Calendar = .current) -> String {
        let money = amount.formatted(fractionDigits: amount.minorUnits % 100 == 0 ? 0 : 2)
        let start = PlanMonth.label(startMonth, calendar: calendar)
        let until = endMonth.map { " to \(PlanMonth.label($0, calendar: calendar))" } ?? ""
        switch cadence {
        case .once: return "\(money) in \(start)"
        case .monthly: return "\(money) a month from \(start)\(until)"
        case .yearly: return "\(money) a year from \(start)\(until)"
        }
    }
}

/// A named set of planned changes, projected against the plain forecast.
public struct PlanScenario: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var events: [PlanEvent]

    public init(id: String, name: String, events: [PlanEvent] = []) {
        self.id = id; self.name = name; self.events = events
    }

    enum CodingKeys: String, CodingKey { case id, name, events }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  events: try c.decodeIfPresent([PlanEvent].self, forKey: .events) ?? [])
    }
}

/// Every scenario, and where each leaves cash after cards at the end of the horizon against the plain forecast.
public struct ScenarioList: Hashable, Codable, Sendable {
    public struct Outcome: Hashable, Codable, Sendable, Identifiable {
        public var scenarioID: String
        /// Cash after cards at the end of the horizon with the scenario's changes.
        public var endBalance: Money
        /// `endBalance` less the plain forecast's: what the scenario's changes add up to by then.
        public var effect: Money
        public var id: String { scenarioID }

        public init(scenarioID: String, endBalance: Money, effect: Money) {
            self.scenarioID = scenarioID; self.endBalance = endBalance; self.effect = effect
        }
    }

    public var horizonMonths: Int
    /// The plain forecast at the end of the horizon.
    public var baselineEnd: Money
    public var scenarios: [PlanScenario]
    /// One per scenario, in the same order.
    public var outcomes: [Outcome]

    public init(horizonMonths: Int, baselineEnd: Money, scenarios: [PlanScenario], outcomes: [Outcome]) {
        self.horizonMonths = horizonMonths; self.baselineEnd = baselineEnd; self.scenarios = scenarios; self.outcomes = outcomes
    }

    public func outcome(for scenarioID: String) -> Outcome? { outcomes.first { $0.scenarioID == scenarioID } }
}

/// "2027-03" month keys as plans use them.
public enum PlanMonth {
    /// (year, month) for a key like "2027-03"; nil for anything else.
    public static func parse(_ key: String) -> (year: Int, month: Int)? {
        guard let m = key.wholeMatch(of: /([0-9]{4})-([0-9]{2})/), let year = Int(m.1), let month = Int(m.2), (1...12).contains(month) else { return nil }
        return (year, month)
    }

    /// Whole months from `from` to `to` (negative when `to` is earlier); nil when either isn't a month key.
    public static func distance(from: String, to: String) -> Int? {
        guard let a = parse(from), let b = parse(to) else { return nil }
        return (b.year - a.year) * 12 + (b.month - a.month)
    }

    /// The key `count` months after `key`.
    public static func adding(_ count: Int, to key: String) -> String? {
        guard let p = parse(key) else { return nil }
        let index = p.year * 12 + (p.month - 1) + count
        return String(format: "%04d-%02d", index / 12, index % 12 + 1)
    }

    /// The key for the month holding `date`.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    /// The first instant of the month a key names.
    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        guard let p = parse(key) else { return nil }
        return calendar.date(from: DateComponents(year: p.year, month: p.month, day: 1))
    }

    /// "March 2027".
    public static func label(_ key: String, calendar: Calendar = .current) -> String {
        guard let date = date(key, calendar: calendar) else { return key }
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

// MARK: - Actions

/// Creates a scenario, or replaces one's name and changes whole (the app toggles a change by saving the scenario with
/// it switched off). Not a tool the assistant can call: it reads scenarios and proposes nothing here.
public struct SavePlanScenario: Hashable, Sendable, Codable {
    /// One planned change, as the editor sends it.
    public struct Event: Hashable, Sendable, Codable {
        /// Nil gives a new change an id.
        public var id: String?
        public var name: String
        public var kind: PlanEvent.Kind
        /// Positive; `kind` says which way it goes.
        public var amount: DecimalAmount
        public var startMonth: String
        public var endMonth: String?
        public var cadence: PlanEvent.Cadence
        /// Nil is on.
        public var isEnabled: Bool?

        public init(id: String? = nil, name: String, kind: PlanEvent.Kind, amount: DecimalAmount, startMonth: String, endMonth: String? = nil,
                    cadence: PlanEvent.Cadence, isEnabled: Bool? = nil) {
            self.id = id; self.name = name; self.kind = kind; self.amount = amount; self.startMonth = startMonth
            self.endMonth = endMonth; self.cadence = cadence; self.isEnabled = isEnabled
        }

        public init(_ event: PlanEvent) {
            self.init(id: event.id, name: event.name, kind: event.kind, amount: DecimalAmount(event.amount), startMonth: event.startMonth,
                      endMonth: event.endMonth, cadence: event.cadence, isEnabled: event.isEnabled)
        }
    }

    /// The scenario to replace; one that isn't there is created with this id. Nil creates one with a new id.
    public var scenarioID: String?
    public var name: String
    public var events: [Event]

    public init(scenarioID: String? = nil, name: String, events: [Event] = []) {
        self.scenarioID = scenarioID; self.name = name; self.events = events
    }

    /// The scenario as it stands, to save back (an undo, or a toggle on top of it).
    public init(_ scenario: PlanScenario) {
        self.init(scenarioID: scenario.id, name: scenario.name, events: scenario.events.map(Event.init))
    }
}

/// Removes a scenario and its changes. The plain forecast is untouched.
public struct DeletePlanScenario: Hashable, Sendable, Codable {
    public var scenarioID: String
    public init(scenarioID: String) { self.scenarioID = scenarioID }
}

/// The scenario calls on clients that talk to a ledger: list, project against one, and the month's cash flow.
public protocol PlanScenariosAPI: Sendable {
    /// Every scenario, with where each leaves cash after cards at the end of `horizonMonths` against the plain forecast.
    func scenarios(horizonMonths: Int) async throws -> ScenarioList
    /// `projection(horizonMonths:goal:)` with a scenario's changes on top, compared with the plain forecast; nil is the
    /// plain forecast.
    func projection(horizonMonths: Int, goal: GoalQuery?, scenarioID: String?) async throws -> Projection
}
