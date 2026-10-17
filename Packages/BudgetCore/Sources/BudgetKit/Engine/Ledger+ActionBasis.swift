import Foundation

/// What an action reaches, as the ledger has it now: a fingerprint of those rows and how many there are. An Ask
/// proposal carries the fingerprint; applying it checks the ledger still gives the same one.
public struct ActionBasis: Codable, Hashable, Sendable {
    public var fingerprint: String
    public var rowCount: Int

    public init(fingerprint: String, rowCount: Int) { self.fingerprint = fingerprint; self.rowCount = rowCount }
}

extension Ledger {
    /// The basis of `action`, or nil when it has none to check (nothing is checked yet).
    func basis(for action: AppAction) throws -> ActionBasis? { nil }
}
