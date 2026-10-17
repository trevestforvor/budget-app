import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// Failed and warning-only sync records are pruned to each link's newest 50; a batch that wrote rows (the unit of Undo)
/// and file imports are never pruned (integration, P1 nit).
@Suite("Sync history pruning")
struct SyncHistoryPruneTests {
    static func record(_ id: String, link: String?, kind: ImportRecord.Kind = .sync, rows: Int = 0, outcome: ImportOutcome, at: Date) -> ImportRecord {
        var report = IngestReport(batchID: id, source: .plaid)
        report.rowsAdded = rows
        return ImportRecord(batchID: id, kind: kind, linkID: link, label: "Harbor sync", report: report, createdAt: at,
                            rolledBack: false, outcome: outcome)
    }

    @Test("Only row-free sync records past the newest 50 per link are prunable")
    func policy() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var records = (0..<60).map { Self.record("b\($0)-failed-x", link: "l1", outcome: .failed, at: start.addingTimeInterval(Double($0) * 3600)) }
        records += (0..<5).map { Self.record("w\($0)-warning-x", link: "l1", outcome: .warning, at: start.addingTimeInterval(-Double($0 + 1) * 3600)) }
        records.append(Self.record("rows-old", link: "l1", rows: 3, outcome: .ok, at: start.addingTimeInterval(-86_400 * 30)))
        records.append(Self.record("file-old", link: nil, kind: .file, outcome: .ok, at: start.addingTimeInterval(-86_400 * 30)))
        records += (0..<10).map { Self.record("o\($0)-failed-x", link: "l2", outcome: .failed, at: start.addingTimeInterval(Double($0) * 60)) }
        let prunable = Set(LinkHealthBook.prunableSyncRecords(records))
        // l1: 65 row-free records, the 15 oldest go (the 5 warnings and the 10 oldest failures).
        #expect(prunable.count == 15)
        #expect(prunable.isSuperset(of: (0..<5).map { "w\($0)-warning-x" }))
        #expect(prunable.isSuperset(of: (0..<10).map { "b\($0)-failed-x" }))
        #expect(!prunable.contains("rows-old"))
        #expect(!prunable.contains("file-old"))
        #expect(prunable.allSatisfy { !$0.hasPrefix("o") })
    }

    @Test("Publishing the links prunes the store and keeps what it shows")
    func publishPrunes() async throws {
        let f = try await ReconnectRouteTests.fixture(needsSignIn: false)
        let now = Date()
        for i in 0..<55 {
            try await f.service.store.upsertImport(Self.record("f\(i)-failed-x", link: ReconnectRouteTests.id, outcome: .failed,
                                                               at: now.addingTimeInterval(-Double(55 - i) * 3600)))
        }
        try await f.service.store.upsertImport(Self.record("rows-1", link: ReconnectRouteTests.id, rows: 2, outcome: .ok,
                                                           at: now.addingTimeInterval(-86_400 * 10)))
        await f.service.sync.publishInstitutions()
        let left = try await f.service.store.imports()
        #expect(left.filter { $0.outcome == .failed }.count == LinkHealthBook.rowFreeRecordsKept)
        #expect(left.contains { $0.batchID == "rows-1" })
        #expect(!left.contains { $0.batchID == "f0-failed-x" })
        let row = try #require(try await f.service.api.serverStatus().institutions.first { $0.id == ReconnectRouteTests.id })
        #expect(row.recentSyncs?.count == 5)
    }
}

/// The stale threshold is 2 days and doesn't scale with the interval, so the interval is capped at a day (S3 nit).
@Suite("Sync interval cap")
struct SyncIntervalCapTests {
    @Test("A larger environment or saved value reads as 24; the dashboard refuses one; 24 and below are kept")
    func capped() async throws {
        var config = TestServer.config()
        config.syncIntervalHours = 72
        let fromEnvironment = ServerSettings(config: config, store: MemoryStore(), sealer: nil, logger: .init(label: "test"))
        #expect(await fromEnvironment.syncIntervalHours == 24)

        let store = MemoryStore()
        try await store.saveServerSettings(StoredServerSettings(values: ["syncIntervalHours": "168.0"]))  // 0.5.x allowed a week
        let saved = ServerSettings(config: TestServer.config(), store: store, sealer: nil, logger: .init(label: "test"))
        try await saved.load()
        #expect(await saved.syncIntervalHours == 24)
        await #expect(throws: BudgetAPIError.self) { try await saved.update(["syncIntervalHours": "48"]) }
        try await saved.update(["syncIntervalHours": "24"])
        #expect(await saved.syncIntervalHours == 24)
        try await saved.update(["syncIntervalHours": "12"])
        #expect(await saved.syncIntervalHours == 12)
    }
}
