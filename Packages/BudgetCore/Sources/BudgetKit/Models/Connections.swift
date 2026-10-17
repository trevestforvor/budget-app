import Foundation

// Wire types for bank connections that stop and get repaired (server 0.6.0). Every enum a server sends decodes
// tolerantly: a value this build doesn't know falls back to a safe case instead of failing the whole response.

/// Why a link stopped. Tolerant: an unknown value decodes as `.transient`.
public enum LinkErrorKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// The bank wants the person to sign in again.
    case needsSignIn
    /// The person (or the bank) withdrew access; only a new link brings it back.
    case revoked
    /// The server's own setup with the provider is wrong (keys, plan, payment).
    case providerSetup
    case rateLimited
    /// Anything that may clear up by itself; the next sync tries again.
    case transient

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .transient
    }
}

/// How the person repairs a link. Tolerant → `.dashboard`.
public enum ReconnectMethod: String, Codable, Hashable, Sendable {
    /// Plaid update mode from the phone (`POST /v1/links/:id/reconnect`).
    case phone
    /// Only the dashboard can.
    case dashboard
    /// Sign in at the provider's own site (`InstitutionLink.reconnectURL`, SimpleFIN Bridge), then try again.
    case providerSite
    /// Access was withdrawn: a fresh link on the dashboard.
    case newLink

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .dashboard
    }
}

/// One bank behind an aggregator link (SimpleFIN), for the dashboard's per-bank status (`LinkSummary.banks`).
public struct LinkBank: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// `.connected` or `.needsReauth`.
    public var status: ConnectionStatus
    public var errorKind: LinkErrorKind?
    public var lastGoodAt: Date?
    /// Ledger account ids.
    public var accountIDs: [String]?

    public init(id: String, name: String, status: ConnectionStatus, errorKind: LinkErrorKind? = nil, lastGoodAt: Date? = nil, accountIDs: [String]? = nil) {
        self.id = id; self.name = name; self.status = status; self.errorKind = errorKind; self.lastGoodAt = lastGoodAt; self.accountIDs = accountIDs
    }
}

/// How fresh one synced account is (`Overview.accountHealth`).
public struct AccountHealth: Identifiable, Hashable, Codable, Sendable {
    /// Tolerant → `.current`.
    public enum State: String, Codable, Hashable, Sendable {
        case current, stale, waitingForSignIn, statementsOverdue, notSynced

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .current
        }
    }

    /// The ledger account id.
    public var id: String
    public var state: State
    public var lastGoodSync: Date?
    public var balanceAsOf: Date?
    /// When it went stale: the start of the episode, which keys its one push.
    public var staleSince: Date?

    public init(id: String, state: State, lastGoodSync: Date? = nil, balanceAsOf: Date? = nil, staleSince: Date? = nil) {
        self.id = id; self.state = state; self.lastGoodSync = lastGoodSync; self.balanceAsOf = balanceAsOf; self.staleSince = staleSince
    }
}

/// One sync of a link, for its recent history.
public struct SyncOutcome: Hashable, Codable, Sendable {
    public var at: Date
    public var ok: Bool
    public var rowsAdded: Int
    public var kind: LinkErrorKind?
    public var message: String?

    public init(at: Date, ok: Bool, rowsAdded: Int, kind: LinkErrorKind? = nil, message: String? = nil) {
        self.at = at; self.ok = ok; self.rowsAdded = rowsAdded; self.kind = kind; self.message = message
    }
}

/// The body of `POST /v1/sync`. No body, or no field, means a scheduled run (what older phones send).
public struct SyncRequest: Codable, Hashable, Sendable {
    /// The person asked (pull to refresh, "Sync now"), so the server may spend a live balance call.
    public var requestedByPerson: Bool?

    public init(requestedByPerson: Bool? = nil) { self.requestedByPerson = requestedByPerson }
}

/// Signing in to a bank again from the phone: one Hosted Link session in Plaid's update mode.
public struct ReconnectSession: Identifiable, Hashable, Codable, Sendable {
    /// waiting → syncing → done; or exited, failed, expired. Tolerant → `.failed`, so the phone stops polling.
    public enum State: String, Codable, Hashable, Sendable {
        case waiting, syncing, done, exited, failed, expired

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }

    /// Unguessable; never logged.
    public var id: String
    public var linkID: String
    public var institution: String
    public var state: State
    /// Plaid's hosted link, only while `.waiting` and only in the response that starts the session. Never logged.
    public var url: String?
    /// The custom scheme the browser session finishes on ("budgetapp-plaid").
    public var callbackScheme: String?
    public var expiresAt: Date
    public var pollAfterSeconds: Int?
    /// Person-readable, on exited, failed and expired.
    public var message: String?
    /// The sync that followed, on `.done`.
    public var result: LinkSyncResult?

    public init(id: String, linkID: String, institution: String, state: State, url: String? = nil, callbackScheme: String? = nil,
                expiresAt: Date, pollAfterSeconds: Int? = nil, message: String? = nil, result: LinkSyncResult? = nil) {
        self.id = id; self.linkID = linkID; self.institution = institution; self.state = state; self.url = url
        self.callbackScheme = callbackScheme; self.expiresAt = expiresAt; self.pollAfterSeconds = pollAfterSeconds
        self.message = message; self.result = result
    }
}

/// What a connection push is about (`userInfo["alert"]`). Tolerant → `.needsSignIn`.
public enum ConnectionAlertKind: String, Codable, Hashable, Sendable, CaseIterable {
    case needsSignIn, revoked, consentExpiring, bankNeedsSignIn, accountStale, providerSetup

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .needsSignIn
    }
}

extension ServerStatus {
    /// Error kinds, consent dates, repair methods, account health, reconnect routes and connection pushes.
    public static let connectionsSince = "0.6.0"
    /// `GET /v1/holdings`.
    public static let holdingsSince = "0.6.0"
    /// `PATCH /v1/accounts/:id`.
    public static let accountEditsSince = "0.6.0"
    /// The `Budget-Basis` header on `POST /v1/actions` (409 when the proposal went stale).
    public static let actionBasisSince = "0.6.0"
    /// Rows held for the person to say whether they're duplicates.
    public static let possibleDuplicatesSince = "0.6.0"
}
