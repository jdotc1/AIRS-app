import AppKit
import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

private actor HistoryHostReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

private actor HistoryReadGate: SnapshotReading {
    private var continuation: CheckedContinuation<EntitlementSnapshot, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(returning: ExampleSnapshots.pair(architecture: .arm64).previous); continuation = nil }
}

final class EntitlementBatchHistoryWorkspaceTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-history-evidence/host/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(_ name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let directory = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("owned synthetic data".utf8).write(to: directory.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    @MainActor
    private func addPair(_ workspace: EntitlementsWorkspace, root: URL) throws {
        workspace.addBatchPair(previous: try app("Previous", root: root), current: try app("Current", root: root), architecture: .arm64)
    }

    @MainActor
    func testHistoryReopensSeparatelyPreservesQueueAndPrimaryAndMissingReportsRemainUnavailable() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"))
        let historyRoot = root.appendingPathComponent("history")
        let history = EntitlementBatchHistory(root: historyRoot)
        let reader = HistoryHostReader()
        let producer = EntitlementsWorkspace(library: library, batchHistory: history, reader: reader)
        try addPair(producer, root: root)
        await producer.runBatch()?.value
        XCTAssertFalse(producer.batchNeedsHistorySave)
        let saved = try await history.entries(); let id = try XCTUnwrap(saved.first?.id)
        let restored = EntitlementsWorkspace(library: library, batchHistory: EntitlementBatchHistory(root: historyRoot), reader: reader)
        restored.loadExample(); let revision = restored.model.reportRevision
        restored.model.browser.query = "primary filter"
        try addPair(restored, root: root)
        let queueIDs = restored.batchPairs.map(\.id)
        await restored.openBatchHistory()?.value
        await restored.loadBatchHistory(id)?.value
        XCTAssertEqual(restored.batchPairs.map(\.id), queueIDs)
        XCTAssertNil(restored.batchResult)
        XCTAssertEqual(restored.model.reportRevision, revision)
        XCTAssertEqual(restored.model.browser.query, "primary filter")
        let row = try XCTUnwrap(restored.selectedBatchHistory?.result.rows.first)
        await restored.reviewHistoryReport(row.id)?.value
        XCTAssertNotNil(restored.savedReport); restored.cancelReview()
        XCTAssertTrue(restored.showingBatchHistory); XCTAssertEqual(restored.model.reportRevision, revision)
        await restored.reviewHistoryReport(row.id)?.value
        restored.openSavedComparison()
        XCTAssertFalse(restored.showingBatchHistory)
        XCTAssertTrue(restored.model.previous.snapshot?.isSavedBaseline == true)
        let adopted = restored.model.reportRevision
        // Removing a complete report does not remove or fabricate its historical outcome.
        try await library.remove(try XCTUnwrap(row.retainedReportID))
        await restored.openBatchHistory()?.value; await restored.loadBatchHistory(id)?.value
        await restored.reviewHistoryReport(row.id)?.value
        XCTAssertNotNil(restored.errorMessage); XCTAssertNil(restored.savedReport)
        XCTAssertEqual(restored.model.reportRevision, adopted)
        XCTAssertEqual(restored.selectedBatchHistory?.result.rows.first?.status, .completed)
        XCTAssertEqual(restored.batchPairs.map(\.id), queueIDs)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
        let audit = AuditWorkspace(); XCTAssertNil(audit.report)
    }

    @MainActor
    func testHistoryFailureVetoesQuitKeepsCurrentOutcomesAndRetryUsesOriginalSettlement() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history")
        try Data("blocked destination".utf8).write(to: historyRoot)
        let history = EntitlementBatchHistory(root: historyRoot)
        let reader = HistoryHostReader()
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"))
        let workspace = EntitlementsWorkspace(library: library, batchHistory: history, reader: reader)
        try addPair(workspace, root: root)
        await workspace.runBatch()?.value
        let settledBefore = Date()
        let batchID = try XCTUnwrap(workspace.batchResult?.id)
        XCTAssertTrue(workspace.batchNeedsHistorySave); XCTAssertNotNil(workspace.batchHistoryFailure)
        workspace.clearBatch(); XCTAssertEqual(workspace.batchResult?.id, batchID)
        workspace.closeBatch()
        let audit = AuditWorkspace(); let navigation = AIRSNavigation(); let fileOpen = AIRSFileOpen(hasModal: { false })
        navigation.showsEntitlements = false
        let delegate = AIRSApplicationDelegate()
        delegate.configureFileOpening(audit: audit, entitlements: workspace, navigation: navigation, fileOpen: fileOpen)
        let ready = await delegate.settleBeforeQuit()
        XCTAssertFalse(ready); XCTAssertTrue(navigation.showsEntitlements); XCTAssertTrue(workspace.showingBatch)
        workspace.errorMessage = nil
        try FileManager.default.removeItem(at: historyRoot)
        await workspace.retryBatchHistorySave()?.value
        XCTAssertFalse(workspace.batchNeedsHistorySave); XCTAssertNil(workspace.batchHistoryFailure)
        let entries = try await history.entries(); XCTAssertEqual(entries.count, 1)
        let record = try await history.load(entries[0].id)
        XCTAssertEqual(record.result.id, batchID); XCTAssertLessThanOrEqual(record.finishedAt, settledBefore)
        await workspace.retryBatchHistorySave()?.value
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
        // History removal is independent of the complete report and current result.
        await workspace.openBatchHistory()?.value
        await workspace.removeBatchHistory(entries[0].id)?.value
        XCTAssertTrue(workspace.batchHistoryEntries.isEmpty)
        XCTAssertEqual(workspace.batchResult?.id, batchID)
        let reports = try await library.entries(); XCTAssertEqual(reports.count, 1)
        let canQuit = await workspace.finishBeforeQuit(); XCTAssertTrue(canQuit)
    }

    @MainActor
    func testPendingReportDefersHistoryAndExportRecoveryBindsExactBytes() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history")
        let history = EntitlementBatchHistory(root: historyRoot)
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"), maximumEntries: 0)
        let reader = HistoryHostReader()
        let workspace = EntitlementsWorkspace(library: library, batchHistory: history, reader: reader)
        try addPair(workspace, root: root)
        await workspace.runBatch()?.value
        XCTAssertTrue(workspace.hasUnretainedBatchReport); XCTAssertTrue(workspace.batchNeedsHistorySave)
        workspace.discardUnsavedBatchHistory(); XCTAssertTrue(workspace.batchNeedsHistorySave)
        let before = try await history.entries(); XCTAssertTrue(before.isEmpty)
        let row = try XCTUnwrap(workspace.batchResult?.rows.first)
        await workspace.exportBatchRecovery(row.id, to: historyRoot.appendingPathComponent("cannot-overwrite.json"))?.value
        XCTAssertNotNil(workspace.errorMessage); XCTAssertTrue(workspace.hasUnretainedBatchReport)
        workspace.errorMessage = nil
        let export = root.appendingPathComponent("recovered.json")
        await workspace.exportBatchRecovery(row.id, to: export)?.value
        XCTAssertFalse(workspace.hasUnretainedBatchReport); XCTAssertFalse(workspace.batchNeedsHistorySave)
        let entries = try await history.entries(); XCTAssertEqual(entries.count, 1)
        let reopened = EntitlementsWorkspace(library: library, batchHistory: EntitlementBatchHistory(root: historyRoot), reader: reader)
        reopened.loadExample(); let revision = reopened.model.reportRevision
        await reopened.openBatchHistory()?.value; await reopened.loadBatchHistory(entries[0].id)?.value
        await reopened.reviewHistoryReport(row.id)?.value
        XCTAssertNotNil(reopened.savedReport); reopened.cancelReview()
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        try EntitlementDiffCore.ComparisonReport(previous: pair.current, current: pair.previous).jsonData().write(to: export)
        await reopened.reviewHistoryReport(row.id)?.value
        XCTAssertNil(reopened.savedReport); XCTAssertTrue(reopened.errorMessage?.contains("changed") == true)
        XCTAssertEqual(reopened.model.reportRevision, revision)
        await workspace.reviewBatchReport(row.id)?.value
        XCTAssertNil(workspace.savedReport); XCTAssertTrue(workspace.errorMessage?.contains("changed") == true)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testHistoryBrowsingCannotReplaceUnsavedOutcomesAndExplicitDiscardPreservesReports() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let history = EntitlementBatchHistory(root: root.appendingPathComponent("history"), maximumEntries: 1)
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"))
        let reader = HistoryHostReader()
        let workspace = EntitlementsWorkspace(library: library, batchHistory: history, reader: reader)
        try addPair(workspace, root: root); await workspace.runBatch()?.value
        let entries = try await history.entries(); let savedID = try XCTUnwrap(entries.first?.id)
        workspace.clearBatch()
        try addPair(workspace, root: root); await workspace.runBatch()?.value
        let pendingID = try XCTUnwrap(workspace.batchResult?.id)
        XCTAssertTrue(workspace.batchNeedsHistorySave)
        await workspace.openBatchHistory()?.value; await workspace.loadBatchHistory(savedID)?.value
        XCTAssertNotEqual(workspace.selectedBatchHistory?.result.id, pendingID)
        XCTAssertEqual(workspace.batchResult?.id, pendingID); XCTAssertTrue(workspace.batchNeedsHistorySave)
        workspace.openBatch(); workspace.discardUnsavedBatchHistory()
        XCTAssertFalse(workspace.batchNeedsHistorySave)
        let reports = try await library.entries(); XCTAssertFalse(reports.isEmpty)
        workspace.clearBatch(); XCTAssertNil(workspace.batchResult)
        let calls = await reader.calls; XCTAssertEqual(calls, 4)
    }

    @MainActor
    func testCancelledReadStillPersistsOutcomesAndHistoryFailureIsNotSuppressed() async throws {
        for capacity in [0, 1] {
            let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
            let history = EntitlementBatchHistory(root: root.appendingPathComponent("history"), maximumEntries: capacity)
            let reader = HistoryReadGate()
            let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")),
                batchHistory: history, reader: reader)
            workspace.loadExample(); let revision = workspace.model.reportRevision
            try addPair(workspace, root: root)
            let run = try XCTUnwrap(workspace.runBatch())
            await reader.started()
            let quit = Task { await workspace.finishBeforeQuit() }
            while !workspace.isTerminating { await Task.yield() }
            await reader.finish()
            let ready = await quit.value; await run.value
            XCTAssertEqual(workspace.model.reportRevision, revision)
            XCTAssertEqual(workspace.batchResult?.rows.first?.status, .cancelled)
            let entries = try await history.entries()
            if capacity == 0 {
                XCTAssertFalse(ready); XCTAssertTrue(workspace.batchNeedsHistorySave)
                XCTAssertNotNil(workspace.batchHistoryFailure); XCTAssertTrue(workspace.showingBatch)
                XCTAssertTrue(entries.isEmpty)
            } else {
                XCTAssertTrue(ready); XCTAssertFalse(workspace.batchNeedsHistorySave)
                let record = try await history.load(XCTUnwrap(entries.first?.id))
                XCTAssertTrue(record.result.cancelled); XCTAssertEqual(record.result.rows.first?.status, .cancelled)
            }
        }
    }
}
