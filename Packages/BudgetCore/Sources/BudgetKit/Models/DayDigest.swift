import Foundation

/// One day's spending as the morning summary tells it: where the money went and the one or two things worth knowing,
/// all computed by the ledger. `summary` is the notification's body: the chat model's short telling of these facts
/// when there is one (checked so it quotes no amount the facts don't hold), otherwise a plain template.
public struct DayDigest: Codable, Hashable, Sendable {
    /// The day, "2026-09-28", in the ledger's calendar.
    public var day: String
    /// Everything spent that day, bills and subscriptions included, net of refunds (`Ledger.netSpend`).
    public var spent: Money
    /// The everyday part, as the week strip counts it.
    public var everydaySpent: Money
    /// Everyday spending on an ordinary day: the average over the four weeks before. Nil without that much history.
    public var typicalDay: Money?
    /// Charges that day in spending categories.
    public var count: Int
    /// Of those, the ones still pending: the total can still move.
    public var pendingCount: Int
    /// Whether the bank has sent anything from this day on. Banks deliver a day's charges hours later (Plaid's arrive
    /// from the next morning), so an empty day that hasn't come in yet isn't a day with nothing spent.
    public var received: Bool
    /// Where it went, most first; at most three.
    public var places: [Place]
    /// What's worth knowing, most useful first.
    public var facts: [Fact]
    public var summary: String
    /// The chat model that wrote `summary`; nil when it's the template.
    public var writtenBy: String?
    /// Why a configured model's telling wasn't used (it didn't answer, or quoted an amount the facts don't hold).
    public var writerProblem: String?

    public struct Place: Codable, Hashable, Sendable {
        public var merchant: String
        public var spent: Money
        public var count: Int
        /// The category of its largest charge.
        public var category: String?

        public init(merchant: String, spent: Money, count: Int, category: String?) {
            self.merchant = merchant
            self.spent = spent
            self.count = count
            self.category = category
        }
    }

    public struct Fact: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// `bills` also carries a card bill due in the next few days, or past due (server 0.5.0): a new kind would fail
            /// to decode on an app from before this fallback.
            case pace, firstTime, bills, safeToSpend, pending

            /// A kind a later version adds reads as `.bills`, instead of failing a saved digest's load.
            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bills
            }
        }
        public var kind: Kind
        /// One plain sentence, amounts written out.
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public init(day: String, spent: Money, everydaySpent: Money, typicalDay: Money?, count: Int, pendingCount: Int, received: Bool = true,
                places: [Place], facts: [Fact], summary: String, writtenBy: String?, writerProblem: String? = nil) {
        self.day = day
        self.spent = spent
        self.everydaySpent = everydaySpent
        self.typicalDay = typicalDay
        self.count = count
        self.pendingCount = pendingCount
        self.received = received
        self.places = places
        self.facts = facts
        self.summary = summary
        self.writtenBy = writtenBy
        self.writerProblem = writerProblem
    }

    /// The notification's title for the day it describes, e.g. "Yesterday · $120".
    public func title(_ when: String) -> String {
        guard count > 0 else { return received ? "\(when) · nothing spent" : "\(when) · not in from the bank yet" }
        return "\(when) · \(spent.formatted(fractionDigits: spent.minorUnits < 10_000 ? 2 : 0))"
    }

    // A digest saved before `received` existed was of a day that had come in.
    enum CodingKeys: String, CodingKey { case day, spent, everydaySpent, typicalDay, count, pendingCount, received, places, facts, summary, writtenBy, writerProblem }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        spent = try c.decode(Money.self, forKey: .spent)
        everydaySpent = try c.decode(Money.self, forKey: .everydaySpent)
        typicalDay = try c.decodeIfPresent(Money.self, forKey: .typicalDay)
        count = try c.decode(Int.self, forKey: .count)
        pendingCount = try c.decode(Int.self, forKey: .pendingCount)
        received = try c.decodeIfPresent(Bool.self, forKey: .received) ?? true
        places = try c.decode([Place].self, forKey: .places)
        facts = try c.decode([Fact].self, forKey: .facts)
        summary = try c.decode(String.self, forKey: .summary)
        writtenBy = try c.decodeIfPresent(String.self, forKey: .writtenBy)
        writerProblem = try c.decodeIfPresent(String.self, forKey: .writerProblem)
    }

    /// Whether `other` tells the same day the same way: every figure and fact equal, whoever wrote the summary. A
    /// cached summary is reused only while this holds, so a late-posting charge gets a new one.
    public func sameFacts(as other: DayDigest) -> Bool {
        var a = self, b = other
        (a.summary, a.writtenBy, a.writerProblem, b.summary, b.writtenBy, b.writerProblem) = ("", nil, nil, "", nil, nil)
        return a == b
    }
}

/// What the phone tells the server so the morning summary reaches it at the right local time.
public struct DeviceRegistration: Codable, Hashable, Sendable {
    public enum Environment: String, Codable, Sendable { case sandbox, production }
    /// The APNs device token, hex.
    public var token: String
    /// Development builds get sandbox tokens; TestFlight and the App Store, production ones.
    public var environment: Environment
    /// The phone's time zone right now ("Asia/Tokyo"): the summary goes out at `hour`:`minute` there, so it follows a trip.
    public var timeZone: String
    public var enabled: Bool
    public var hour: Int
    public var minute: Int

    public init(token: String, environment: Environment, timeZone: String, enabled: Bool, hour: Int = 9, minute: Int = 30) {
        self.token = token
        self.environment = environment
        self.timeZone = timeZone
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
    }
}

/// The server's side of one phone's morning summary.
public struct DeviceStatus: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var timeZone: String
    public var hour: Int
    public var minute: Int
    /// The phone's local date the last summary went out on.
    public var lastSentDay: String?
    /// Why the last attempt failed, in words; nil once one goes through.
    public var lastError: String?
    /// Whether the server has an APNs key to send with. Without one nothing can arrive.
    public var pushConfigured: Bool

    public init(enabled: Bool, timeZone: String, hour: Int, minute: Int, lastSentDay: String?, lastError: String?, pushConfigured: Bool) {
        self.enabled = enabled
        self.timeZone = timeZone
        self.hour = hour
        self.minute = minute
        self.lastSentDay = lastSentDay
        self.lastError = lastError
        self.pushConfigured = pushConfigured
    }
}

/// The morning summary's two calls, on clients that talk to a server (the demo has none to send from).
public protocol MorningSummaryAPI: Sendable {
    /// Turns the summary on or off for this phone, or tells the server where the phone is now.
    func registerDevice(_ registration: DeviceRegistration) async throws -> DeviceStatus
    /// Sends yesterday's summary to this phone now, whatever the time.
    func sendTestSummary(token: String) async throws -> DeviceStatus
}
