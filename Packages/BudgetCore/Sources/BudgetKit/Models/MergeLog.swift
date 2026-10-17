import Foundation

/// A row the ledger merged away, skipped or dropped as a duplicate or a settled pending row, with both ids and a full
/// copy of what went, so the person can see it and bring it back.
public struct RowMergeRecord: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// An incoming row matched one already here and wasn't added.
        case skippedIncoming
        /// A statement copy was swept once the provider's own row arrived.
        case sweptFileCopy
        /// The person said two rows are the same.
        case duplicateResolved
        /// A pending row replaced by its posted row.
        case pendingSettled
        /// A pending row the provider stopped sending.
        case pendingDropped
    }

    public var id: String
    public var kind: Kind
    public var at: Date
    public var batchID: String?
    /// The row that stays; nil for `pendingDropped`.
    public var keptID: String?
    /// The row removed, or never added.
    public var droppedID: String
    /// A full copy, for undo.
    public var dropped: LedgerTransaction
    /// The kept row before fields were carried onto it.
    public var keptBefore: LedgerTransaction?
    public var undoneAt: Date?

    public init(id: String, kind: Kind, at: Date, batchID: String? = nil, keptID: String? = nil, droppedID: String, dropped: LedgerTransaction,
                keptBefore: LedgerTransaction? = nil, undoneAt: Date? = nil) {
        self.id = id; self.kind = kind; self.at = at; self.batchID = batchID; self.keptID = keptID; self.droppedID = droppedID
        self.dropped = dropped; self.keptBefore = keptBefore; self.undoneAt = undoneAt
    }
}
