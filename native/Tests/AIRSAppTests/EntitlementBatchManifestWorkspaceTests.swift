import AppKit
import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

private actor ManifestHostReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}
private actor ManifestReadGate {
    private var continuation: CheckedContinuation<EntitlementBatchManifest, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> EntitlementBatchManifest {
        await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ manifest: EntitlementBatchManifest) { continuation?.resume(returning: manifest); continuation = nil }
}

final class EntitlementBatchManifestWorkspaceTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-manifest-evidence/host/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func pair(in root: URL, suffix: String = "", architecture: Architecture = .arm64) -> EntitlementBatchPair {
        .init(previous: root.appendingPathComponent("Previous\(suffix).app", isDirectory: true),
              current: root.appendingPathComponent("Current\(suffix).app", isDirectory: true), architecture: architecture)
    }
    private func createAppData(_ url: URL) throws {
        let directory = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Owned fixture data; never executed".utf8).write(to: directory.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    @MainActor
    private func add(_ pair: EntitlementBatchPair, to workspace: EntitlementsWorkspace) {
        workspace.addBatchPair(previous: pair.previous, current: pair.current, architecture: pair.architecture)
    }

    @MainActor
    func testReviewCancelAndExplicitAdoptionPreservePrimaryAndQueueWithoutAppReads() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = ManifestHostReader()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        workspace.loadExample(); let primary = workspace.model.reportRevision
        workspace.model.browser.query = "primary filter"
        add(pair(in: root, suffix: "Existing"), to: workspace)
        let originalIDs = workspace.batchPairs.map(\.id)
        let selected = pair(in: root, suffix: "Imported", architecture: .x86_64)
        let source = root.appendingPathComponent("plan.json")
        try EntitlementBatchManifest(pairs: [selected, selected]).data().write(to: source)
        await workspace.openBatchManifest(source)?.value
        let firstReview = try XCTUnwrap(workspace.batchManifestReview)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        XCTAssertEqual(firstReview.replacedPairCount, 1)
        XCTAssertTrue(workspace.isBusy); XCTAssertFalse(workspace.canRunBatch)
        workspace.clearBatch(); add(selected, to: workspace)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        let audit = AuditWorkspace(), navigation = AIRSNavigation(), fileOpen = AIRSFileOpen(hasModal: { false })
        XCTAssertNil(fileOpen.open([source], audit: audit, entitlements: workspace, navigation: navigation))
        workspace.cancelBatchManifest(firstReview.id)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        await workspace.openBatchManifest(source)?.value
        let review = try XCTUnwrap(workspace.batchManifestReview)
        XCTAssertNotEqual(review.id, firstReview.id)
        workspace.adoptBatchManifest(firstReview.id); XCTAssertNotNil(workspace.batchManifestReview)
        workspace.adoptBatchManifest(review.id)
        XCTAssertNil(workspace.batchManifestReview)
        XCTAssertEqual(workspace.batchPairs.map(\.id), review.pairs.map(\.id))
        XCTAssertEqual(workspace.batchPairs.count, 2); XCTAssertEqual(Set(workspace.batchPairs.map(\.id)).count, 2)
        XCTAssertEqual(workspace.batchPairs.map(\.architecture), [.x86_64, .x86_64])
        XCTAssertNil(workspace.batchResult); XCTAssertNil(workspace.batchCheckpoint)
        XCTAssertEqual(workspace.model.reportRevision, primary); XCTAssertEqual(workspace.model.browser.query, "primary filter")
        XCTAssertNil(audit.report)
        let calls = await reader.calls; XCTAssertEqual(calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.previous.path))
    }

    @MainActor
    func testMalformedAndCancelledManifestReadsCannotPublishOrReplaceQueue() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = ManifestReadGate(), reader = ManifestHostReader()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library")),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader,
            readBatchManifest: { url in
                if url.lastPathComponent == "slow.json" { return await gate.read() }
                return try await EntitlementsWorkspace.readManifest(url)
            })
        add(pair(in: root), to: workspace); let originalIDs = workspace.batchPairs.map(\.id)
        let malformed = root.appendingPathComponent("bad.json")
        try Data("{\"kind\":\"airs-entitlement-batch-history\"}".utf8).write(to: malformed)
        await workspace.openBatchManifest(malformed)?.value
        XCTAssertNotNil(workspace.errorMessage); XCTAssertNil(workspace.batchManifestReview)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        workspace.errorMessage = nil
        let task = try XCTUnwrap(workspace.openBatchManifest(root.appendingPathComponent("slow.json")))
        await gate.started()
        XCTAssertNil(workspace.runBatch()); XCTAssertNil(workspace.openBatchManifest(malformed))
        workspace.cancel()
        await gate.finish(try EntitlementBatchManifest(pairs: [pair(in: root, suffix: "Other")]))
        await task.value
        XCTAssertNil(workspace.batchManifestReview); XCTAssertFalse(workspace.isBusy)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        let calls = await reader.calls; XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testExportProtectsSourceAndCannotClearPendingReportOrImportOverResults() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = pair(in: root)
        try createAppData(selected.previous); try createAppData(selected.current)
        let source = root.appendingPathComponent("source-plan.json")
        let data = try EntitlementBatchManifest(pairs: [selected]).data(); try data.write(to: source)
        let reader = ManifestHostReader()
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("library"), maximumEntries: 0),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")), reader: reader)
        await workspace.openBatchManifest(source)?.value
        workspace.adoptBatchManifest(try XCTUnwrap(workspace.batchManifestReview).id)
        await workspace.runBatch()?.value
        let resultID = try XCTUnwrap(workspace.batchResult?.id)
        let checkpointID = try XCTUnwrap(workspace.batchCheckpoint?.checkpointRevision)
        let pending = try XCTUnwrap(workspace.batchResult?.rows[0].unretainedData)
        XCTAssertFalse(workspace.canImportBatchManifest); XCTAssertNil(workspace.openBatchManifest(source))
        XCTAssertTrue(workspace.canExportBatchManifest)
        await workspace.exportBatchManifest(to: source)?.value
        XCTAssertNotNil(workspace.errorMessage); XCTAssertEqual(try Data(contentsOf: source), data)
        workspace.errorMessage = nil
        let output = root.appendingPathComponent("selection-copy.json")
        await workspace.exportBatchManifest(to: output)?.value
        XCTAssertNil(workspace.errorMessage)
        let exported = try EntitlementBatchManifest.read(output)
        XCTAssertEqual(exported.pairs.count, 1); XCTAssertEqual(exported.pairs[0].previousPath, selected.previous.path)
        XCTAssertEqual(workspace.batchResult?.id, resultID)
        XCTAssertEqual(workspace.batchCheckpoint?.checkpointRevision, checkpointID)
        XCTAssertEqual(workspace.batchResult?.rows[0].unretainedData, pending)
        XCTAssertTrue(workspace.batchNeedsHistorySave); XCTAssertTrue(workspace.requiresQuitSettlement)
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }
}
