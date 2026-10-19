import AppKit
import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

private actor RecoveryHostReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}
private actor RecoveryHostGate: SnapshotReading {
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

final class EntitlementBatchRecoveryWorkspaceTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-recovery-evidence/host/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(_ name: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let directory = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("owned input data".utf8).write(to: directory.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    @MainActor
    func testPendingReportReopensWithoutSourcesAndPreservesPrimaryThenRetainsWithoutReading() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = try app("Previous", root: root), current = try app("Current", root: root)
        let history = EntitlementBatchHistory(root: root.appendingPathComponent("history"))
        let recovery = EntitlementBatchRecovery(root: root.appendingPathComponent("recovery"))
        let reader = RecoveryHostReader()
        let producer = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library"), maximumEntries: 0),
            batchHistory: history, recovery: recovery, reader: reader)
        producer.addBatchPair(previous: previous, current: current, architecture: .arm64)
        await producer.runBatch()?.value
        let checkpoint = try XCTUnwrap(producer.batchCheckpoint)
        let bytes = try XCTUnwrap(checkpoint.result.rows.first?.unretainedData)
        XCTAssertTrue(producer.canLeaveForRecovery)
        producer.leaveForRecovery(); XCTAssertNil(producer.batchResult)
        try FileManager.default.removeItem(at: previous); try FileManager.default.removeItem(at: current)
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"))
        let restored = EntitlementsWorkspace(library: library, batchHistory: history, recovery: recovery, reader: reader)
        restored.loadExample(); let revision = restored.model.reportRevision
        restored.model.browser.query = "keep primary"
        await restored.openBatchRecovery()?.value
        await restored.recoverBatch(checkpoint.id)?.value
        XCTAssertEqual(restored.batchResult?.rows.first?.unretainedData, bytes)
        XCTAssertEqual(restored.model.reportRevision, revision)
        XCTAssertEqual(restored.model.browser.query, "keep primary")
        XCTAssertFalse(restored.canResumeBatch)
        await restored.retryBatchRetention(checkpoint.result.rows[0].id)?.value
        XCTAssertNil(restored.errorMessage)
        XCTAssertFalse(restored.hasUnretainedBatchReport); XCTAssertFalse(restored.batchNeedsHistorySave)
        let saved = try await recovery.load(checkpoint.id)
        XCTAssertNotNil(saved.historyRecordID); XCTAssertNotNil(saved.result.rows[0].retainedReportID)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
        let reports = try await library.entries(); XCTAssertEqual(reports.count, 1)
        restored.clearBatch(); XCTAssertNil(restored.batchCheckpoint)
        XCTAssertEqual(restored.model.reportRevision, revision)
    }

    @MainActor
    func testFailedCheckpointPreventsReadsAndQuitUntilRetryThenExplicitResume() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let recoveryRoot = root.appendingPathComponent("recovery")
        let recovery = EntitlementBatchRecovery(root: recoveryRoot, maximumRecoveryBytes: 0)
        let reader = RecoveryHostReader()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), recovery: recovery, reader: reader)
        workspace.addBatchPair(previous: try app("Previous", root: root), current: try app("Current", root: root), architecture: .arm64)
        await workspace.runBatch()?.value
        XCTAssertTrue(workspace.batchNeedsCheckpointSave)
        XCTAssertTrue(workspace.hasUnretainedBatchReport)
        XCTAssertFalse(workspace.canLeaveForRecovery); XCTAssertFalse(workspace.canResumeBatch)
        workspace.clearBatch(); XCTAssertNotNil(workspace.batchResult)
        let quit = await workspace.finishBeforeQuit(); XCTAssertFalse(quit)
        workspace.errorMessage = nil
        // Export recovers complete bytes even though the pending spool could not fit.
        let row = try XCTUnwrap(workspace.batchResult?.rows.first)
        await workspace.exportBatchRecovery(row.id, to: root.appendingPathComponent("saved.json"))?.value
        XCTAssertFalse(workspace.batchNeedsCheckpointSave)
        XCTAssertFalse(workspace.hasUnretainedBatchReport); XCTAssertFalse(workspace.batchNeedsHistorySave)
        let latest = try await recovery.load(XCTUnwrap(workspace.batchResult?.id))
        XCTAssertEqual(latest.result.rows[0].exportedReportURL, root.appendingPathComponent("saved.json"))
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testOwnedRunRejectsOtherRecoveryAndUnsavedHistoryBlocksResume() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let recoveryRoot = root.appendingPathComponent("recovery")
        let recovery = EntitlementBatchRecovery(root: recoveryRoot)
        let reader = RecoveryHostGate()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history"), maximumEntries: 0), recovery: recovery, reader: reader)
        workspace.addBatchPair(previous: try app("Previous", root: root), current: try app("Current", root: root), architecture: .arm64)
        let run = try XCTUnwrap(workspace.runBatch()); await reader.started()
        let checkpoint = try XCTUnwrap(workspace.batchCheckpoint)
        let contender = EntitlementBatchRecovery(root: recoveryRoot)
        do { _ = try await contender.recover(try await contender.load(checkpoint.id)); XCTFail("owned run must reject recovery") } catch {}
        workspace.cancel(); await reader.finish(); await run.value
        XCTAssertTrue(workspace.batchNeedsHistorySave); XCTAssertFalse(workspace.batchNeedsCheckpointSave)
        XCTAssertFalse(workspace.canResumeBatch); XCTAssertNil(workspace.resumeBatch())
        workspace.discardUnsavedBatchHistory(); XCTAssertTrue(workspace.canResumeBatch)
        workspace.leaveForRecovery(); XCTAssertNil(workspace.batchResult)
        // A nonempty user queue cannot be silently replaced by recovery.
        workspace.addBatchPair(previous: try app("Previous2", root: root), current: try app("Current2", root: root), architecture: .arm64)
        XCTAssertNil(workspace.recoverBatch(checkpoint.id)); XCTAssertEqual(workspace.batchPairs.count, 1)
    }
}
