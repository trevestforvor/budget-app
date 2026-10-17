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

/// A row added that might be the same charge as one already here, with the rows it could be (`GET /v1/duplicates`).
/// The person answers with `POST /v1/duplicates/:id`: Same charge (one of `candidates`) or Keep both.
public struct PossibleDuplicate: Identifiable, Hashable, Codable, Sendable {
    /// The added row's id.
    public var id: String
    public var row: LedgerTransaction
    /// Best match first.
    public var candidates: [LedgerTransaction]

    public init(id: String, row: LedgerTransaction, candidates: [LedgerTransaction]) { self.id = id; self.row = row; self.candidates = candidates }
}

/// What Bring back did (`POST /v1/merges/:id/undo`, `POST /v1/imports/:batch/merges/undo`).
public struct MergeUndoResult: Hashable, Codable, Sendable {
    /// Rows that came back.
    public var restored: Int
    /// Of those, filed now: by a rule, merchant memory or a transfer match, or with the category they had when merged.
    public var filed: Int
    /// Waiting in Review for a category.
    public var toReview: Int
    /// Left for the decision model, which files them when the server next syncs or imports, a few hundred at a time.
    public var waiting: Int

    public init(restored: Int, filed: Int, toReview: Int, waiting: Int) {
        self.restored = restored; self.filed = filed; self.toReview = toReview; self.waiting = waiting
    }
}
