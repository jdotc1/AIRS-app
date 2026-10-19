import AppKit
import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

private actor BatchHostReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

private actor BatchHostReadGate: SnapshotReading {
    private var continuation: CheckedContinuation<EntitlementSnapshot, Never>?
    private var starting: CheckedContinuation<Void, Never>?
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        await withCheckedContinuation { continuation = $0; starting?.resume(); starting = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { starting = $0 }
    }
    func finish() { continuation?.resume(returning: ExampleSnapshots.pair(architecture: .arm64).previous); continuation = nil }
}

final class EntitlementBatchWorkspaceTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-batch-evidence/host/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("owned fixture".utf8).write(to: macOS.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    @MainActor
    private func addPair(to workspace: EntitlementsWorkspace, root: URL, suffix: String = "") throws {
        workspace.addBatchPair(previous: try app("Previous\(suffix)", in: root), current: try app("Current\(suffix)", in: root), architecture: .arm64)
    }

    @MainActor
    func testBatchRetainsResultsWithoutReplacingPrimaryComparisonAndReviewRemainsExplicit() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"))
        let reader = BatchHostReader()
        let workspace = EntitlementsWorkspace(library: library, batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        workspace.loadExample(); let revision = workspace.model.reportRevision
        workspace.model.browser.query = "keep this primary filter"
        let audit = AuditWorkspace(); let navigation = AIRSNavigation(); let fileOpen = AIRSFileOpen(hasModal: { false })
        try addPair(to: workspace, root: root)
        workspace.openBatch()
        XCTAssertTrue(workspace.showingBatch); XCTAssertFalse(workspace.canFindEntitlement)
        let run = try XCTUnwrap(workspace.runBatch())
        XCTAssertTrue(workspace.isBusy); XCTAssertFalse(workspace.canEditBatch)
        XCTAssertNil(workspace.runBatch())
        XCTAssertNil(fileOpen.open([root.appendingPathComponent("unread.json")], audit: audit, entitlements: workspace, navigation: navigation))
        workspace.clear(); XCTAssertEqual(workspace.model.reportRevision, revision)
        await run.value
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertEqual(workspace.model.browser.query, "keep this primary filter")
        XCTAssertNil(audit.report)
        let row = try XCTUnwrap(workspace.batchResult?.rows.first)
        XCTAssertEqual(row.status, .completed); XCTAssertNotNil(row.retainedReportID)
        let entries = try await library.entries(); XCTAssertEqual(entries.count, 1)
        await workspace.reviewBatchReport(row.id)?.value
        XCTAssertEqual(workspace.model.reportRevision, revision)
        workspace.cancelReview(); XCTAssertTrue(workspace.showingBatch)
        await workspace.reviewBatchReport(row.id)?.value
        workspace.openSavedComparison()
        XCTAssertFalse(workspace.showingBatch)
        XCTAssertNotEqual(workspace.model.reportRevision, revision)
        XCTAssertTrue(workspace.model.previous.snapshot?.isSavedBaseline == true)
        XCTAssertNotNil(workspace.batchResult)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testFailedRetentionRefusesQuitVisiblyAndExactExportRecoversWithoutReread() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = EntitlementReportLibrary(root: root.appendingPathComponent("library"), maximumEntries: 0)
        let reader = BatchHostReader()
        let workspace = EntitlementsWorkspace(library: library, batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        workspace.loadExample(); let revision = workspace.model.reportRevision
        try addPair(to: workspace, root: root)
        await workspace.runBatch()?.value
        let row = try XCTUnwrap(workspace.batchResult?.rows.first)
        let original = try XCTUnwrap(row.unretainedData)
        XCTAssertTrue(workspace.requiresQuitSettlement)
        workspace.clearBatch(); XCTAssertNotNil(workspace.batchResult)
        XCTAssertNil(workspace.runBatch())
        workspace.closeBatch()
        let audit = AuditWorkspace(); let navigation = AIRSNavigation(); let fileOpen = AIRSFileOpen(hasModal: { false })
        navigation.showsEntitlements = false
        let delegate = AIRSApplicationDelegate()
        delegate.configureFileOpening(audit: audit, entitlements: workspace, navigation: navigation, fileOpen: fileOpen)
        let ready = await delegate.settleBeforeQuit()
        XCTAssertFalse(ready)
        XCTAssertTrue(navigation.showsEntitlements); XCTAssertTrue(workspace.showingBatch)
        XCTAssertNotNil(workspace.errorMessage); XCTAssertFalse(workspace.isTerminating)
        workspace.errorMessage = nil
        let protected = row.pair.previous.appendingPathComponent("Contents/MacOS/fixture")
        let source = try Data(contentsOf: protected)
        await workspace.exportBatchRecovery(row.id, to: protected)?.value
        XCTAssertEqual(try Data(contentsOf: protected), source)
        XCTAssertTrue(workspace.hasUnretainedBatchReport)
        workspace.errorMessage = nil
        let destination = root.appendingPathComponent("recovered.json")
        await workspace.exportBatchRecovery(row.id, to: destination)?.value
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(workspace.hasUnretainedBatchReport)
        XCTAssertEqual(workspace.batchResult?.rows.first?.exportedReportURL, destination)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
        let canQuit = await workspace.finishBeforeQuit(); XCTAssertTrue(canQuit)
    }

    @MainActor
    func testRecoveryCannotOverwriteRetainedLibraryReportAndRetrySavesExactBytes() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library")
        let library = EntitlementReportLibrary(root: libraryRoot, maximumEntries: 1)
        let pair = ExampleSnapshots.structuredPair(architecture: .arm64)
        let prior = try EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current)
        let priorID = try await library.keep(prior)
        let existing = try await library.load(priorID)
        let reader = BatchHostReader()
        let workspace = EntitlementsWorkspace(library: library, batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        try addPair(to: workspace, root: root)
        await workspace.runBatch()?.value
        let row = try XCTUnwrap(workspace.batchResult?.rows.first)
        let pending = try XCTUnwrap(row.unretainedData)
        await workspace.exportBatchRecovery(row.id, to: existing.reportURL)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(try Data(contentsOf: existing.reportURL), existing.data)
        XCTAssertEqual(workspace.batchResult?.rows.first?.unretainedData, pending)
        // Free only this test's prior entry, then recover without another inspection.
        try await library.remove(priorID)
        workspace.errorMessage = nil
        await workspace.retryBatchRetention(row.id)?.value
        let recoveredID = try XCTUnwrap(workspace.batchResult?.rows.first?.retainedReportID)
        let recovered = try await library.load(recoveredID)
        XCTAssertEqual(recovered.data, pending)
        XCTAssertFalse(workspace.hasUnretainedBatchReport)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testQuitDuringBatchSettlesReadAndPreservesIdlePrimarySession() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = BatchHostReadGate()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")), batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        workspace.loadExample(); let revision = workspace.model.reportRevision
        try addPair(to: workspace, root: root, suffix: "1")
        try addPair(to: workspace, root: root, suffix: "2")
        let run = try XCTUnwrap(workspace.runBatch())
        await reader.started()
        let quit = Task { await workspace.finishBeforeQuit() }
        while !workspace.isTerminating { await Task.yield() }
        XCTAssertTrue(workspace.isWorking)
        await reader.finish()
        let ready = await quit.value; await run.value
        XCTAssertTrue(ready)
        XCTAssertEqual(workspace.batchResult?.rows.map(\.status), [.cancelled, .notStarted])
        XCTAssertEqual(workspace.model.reportRevision, revision)
        workspace.resumeAfterCancelledQuit()
        XCTAssertFalse(workspace.isBusy)
    }
}
