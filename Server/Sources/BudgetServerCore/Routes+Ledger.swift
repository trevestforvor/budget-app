import BudgetKit
import Foundation
import Hummingbird

/// Undo plans, hiding a batch, account edits, possible duplicates and the merge log, and the statement-id dry run.
func addLedgerSafetyRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, surface: Surface) {
    /// An account's kind, nickname or last digits (`AccountChange`) → `AccountChangeResult`, with what to check and how
    /// many rows went back to review. On both surfaces: the phone's sheet and the dashboard's drawer. Undo is a second
    /// PATCH with the previous values. 404 for an unknown account, 422 for a nickname or digits it won't keep.
    router.patch("/v1/accounts/:id") { request, context in
        let change = try await HTTP.body(AccountChange.self, request, limit: 64 * 1024)
        return try HTTP.json(try await service.api.updateAccount(id: try HTTP.rowID(context), change))
    }

    /// Rows added that might be the same charge as one already here (`[PossibleDuplicate]`), each with its candidates.
    router.get("/v1/duplicates") { _, _ in try HTTP.json(await service.api.possibleDuplicates()) }

    /// The person's answer on a possible duplicate: `{"sameAs": "<row id>"}` (Same charge) merges the two and logs it;
    /// `{"sameAs": null}` (Keep both) clears the question. → `{merged: RowMergeRecord | null}`. On both surfaces.
    router.post("/v1/duplicates/:id") { request, context in
        let body = try await HTTP.body(DuplicateAnswer.self, request, limit: 64 * 1024)
        return try HTTP.json(MergedResponse(merged: try await service.api.resolveDuplicate(rowID: try HTTP.rowID(context), sameAs: body.sameAs)))
    }

    if surface == .dashboard {
        /// The merge log, newest first (`[RowMergeRecord]`): rows skipped as already here, swept statement copies and
        /// resolved duplicates, each with both ids. `?batch=<id>` gives one import's.
        router.get("/v1/merges") { request, _ in
            try HTTP.json(await service.api.merges(batchID: request.uri.queryParameters.get("batch")))
        }

        /// Brings one logged row back → `{restored: 1}`. 404 for an unknown entry, 422 when it's already back.
        router.post("/v1/merges/:id/undo") { _, context in
            try HTTP.json(["restored": try await service.api.undoMerge(id: try HTTP.rowID(context))])
        }

        /// "Import the skipped rows anyway": every row the batch skipped as already here comes back → `{restored: n}`.
        router.post("/v1/imports/:batch/merges/undo") { _, context in
            let batch = try context.parameters.require("batch")
            return try HTTP.json(["restored": try await service.api.undoSkipped(batchID: batch)])
        }

        /// What the statement-id upgrade would rename now (`LedgerMigrations.StatementIDCounts`), counts only. Useful
        /// in `BUDGET_STATEMENT_ID_MIGRATION=audit` on a restored copy; a normal start upgrades before it serves, so 0s.
        router.get("/dash/maintenance/statement-ids") { _, _ in try HTTP.json(await LedgerMigrations.statementIDCounts(service)) }
    }
}

struct DuplicateAnswer: Decodable { let sameAs: String? }

/// `{merged: …}`, with an explicit null for Keep both.
struct MergedResponse: Encodable {
    let merged: RowMergeRecord?

    enum CodingKeys: String, CodingKey { case merged }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(merged, forKey: .merged)
    }
}
