import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

@MainActor
private final class HistoryRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
    func clearRecentDocuments() { recentDocumentURLs = [] }
}

final class BatchHistoryWorkspaceTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture() throws -> (URL, [URL], Data) {
        let root = project.appendingPathComponent("build/batch-history-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = ["first.input", "second.input", "third.input"].map { root.appendingPathComponent($0) }
        for input in inputs { try Data("Owned queue input, not executed".utf8).write(to: input) }
        return (root, inputs, try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json")))
    }
    @MainActor
    private func settle(_ workspace: AuditWorkspace) async throws {
        for _ in 0..<500 {
            if !workspace.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned history operation did not settle")
    }

    @MainActor
    func testNewWorkspaceLoadsAndResumesWithoutReplacingPriorCurrentReport() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history"); let history = BatchHistory(root: url)
        let library = ReportLibrary(root: root.appendingPathComponent("library"))
        let first = AuditWorkspace(library: library, recents: HistoryRecents(), batchAudit: { input in
            if input == inputs[1] { throw CancellationError() }; return raw
        }, batchHistory: history)
        first.startBatch(inputs); try await settle(first)
        let initial = try XCTUnwrap(first.batchSnapshot)
        XCTAssertEqual(initial.items.map(\.status), [.completed, .cancelled, .notStarted])
        let workspace = AuditWorkspace(library: library, recents: HistoryRecents(), batchAudit: { input in
            XCTAssertNotEqual(input, inputs[0], "Completed image was replayed")
            return raw
        }, batchHistory: BatchHistory(root: url))
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let current = try XCTUnwrap(workspace.report)
        workspace.openBatchHistory(); try await settle(workspace)
        XCTAssertEqual(workspace.batchHistoryEntries.count, 1)
        workspace.loadBatchHistory(initial.id); try await settle(workspace)
        XCTAssertTrue(workspace.canResumeBatch)
        workspace.resumeBatch(); try await settle(workspace)
        XCTAssertEqual(workspace.batchSnapshot?.items.map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(workspace.batchSnapshot?.id, initial.id)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, current.image.sliceSHA256)
        let latest = try await history.load(initial.id)
        XCTAssertEqual(latest.items[0].retainedReportID, initial.items[0].retainedReportID)
        XCTAssertEqual(latest.items[1].attempts.map(\.status), [.cancelled])
    }

    @MainActor
    func testDurableRecoveryReportSurvivesQuitAndLibraryRetryInNewWorkspace() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library")
        try Data().write(to: libraryURL)
        let historyURL = root.appendingPathComponent("history")
        let workspace = AuditWorkspace(library: ReportLibrary(root: libraryURL), recents: HistoryRecents(), batchAudit: { _ in raw }, batchHistory: BatchHistory(root: historyURL))
        workspace.startBatch(inputs); try await settle(workspace)
        let id = try XCTUnwrap(workspace.batchSnapshot?.id)
        XCTAssertTrue(workspace.hasUnretainedBatchReports)
        XCTAssertFalse(workspace.hasUnsavedBatchHistory)
        let canQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(canQuit)
        try FileManager.default.removeItem(at: libraryURL)
        let reopened = AuditWorkspace(library: ReportLibrary(root: libraryURL), recents: HistoryRecents(), batchAudit: { _ in raw }, batchHistory: BatchHistory(root: historyURL))
        reopened.loadBatchHistory(id); try await settle(reopened)
        let item = try XCTUnwrap(reopened.batchSnapshot?.items.first)
        XCTAssertEqual(item.unretainedData, raw)
        XCTAssertFalse(reopened.canResumeBatch)
        reopened.retryBatchRetention(item)
        let retryQuit = await reopened.finishBeforeQuit()
        XCTAssertTrue(retryQuit)
        let saved = try await BatchHistory(root: historyURL).load(id)
        XCTAssertNil(saved.items[0].unretainedData)
        let reportID = try XCTUnwrap(saved.items[0].retainedReportID)
        let kept = try await ReportLibrary(root: libraryURL).load(reportID)
        XCTAssertEqual(kept.data, raw)
    }

    @MainActor
    func testUnsavedCheckpointBlocksQuitUntilExplicitRetentionRepairsIt() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let history = BatchHistory(root: root.appendingPathComponent("history"), maximumRecoveryBytes: raw.count - 1)
        let workspace = AuditWorkspace(library: ReportLibrary(root: root.appendingPathComponent("library")), recents: HistoryRecents(), batchAudit: { _ in raw }, batchHistory: history)
        workspace.startBatch(inputs); try await settle(workspace)
        XCTAssertTrue(workspace.hasUnsavedBatchHistory)
        XCTAssertEqual(workspace.batchSnapshot?.items.first?.unretainedData, raw)
        let firstQuit = await workspace.finishBeforeQuit()
        XCTAssertFalse(firstQuit)
        let item = try XCTUnwrap(workspace.batchSnapshot?.items.first)
        workspace.retryBatchRetention(item)
        let nextQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(nextQuit)
        XCTAssertFalse(workspace.hasUnsavedBatchHistory)
        XCTAssertFalse(workspace.hasUnretainedBatchReports)
    }

    @MainActor
    func testInvalidHistoryDoesNotReplaceCurrentReportAndRemovalKeepsLibrary() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("history")
        let library = ReportLibrary(root: root.appendingPathComponent("library"))
        let workspace = AuditWorkspace(library: library, recents: HistoryRecents(), batchAudit: { _ in raw }, batchHistory: BatchHistory(root: historyURL))
        workspace.startBatch([inputs[0]]); try await settle(workspace)
        let snapshot = try XCTUnwrap(workspace.batchSnapshot)
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let current = workspace.report?.image.sliceSHA256
        try Data("{}".utf8).write(to: historyURL.appendingPathComponent("\(snapshot.id.uuidString)/checkpoint.json"))
        workspace.loadBatchHistory(snapshot.id); try await settle(workspace)
        XCTAssertTrue(workspace.showingError)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, current)
        workspace.removeBatchHistory(snapshot.id); try await settle(workspace)
        XCTAssertNil(workspace.batchSnapshot)
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, current)
    }
}
