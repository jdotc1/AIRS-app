import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

@MainActor
private final class BatchComparisonRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) {}
    func clearRecentDocuments() {}
}
final class BatchComparisonWorkspaceTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    @MainActor private func settle(_ workspace: AuditWorkspace) async throws {
        for _ in 0..<500 { if !workspace.isBusy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Batch comparison did not settle")
    }
    private func fixture() throws -> (URL, Data, Data, Data) {
        let root = project.appendingPathComponent("build/batch-comparison-evidence/tests/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json")),
                try Data(contentsOf: project.appendingPathComponent("examples/after.audit.json")),
                try Data(contentsOf: project.appendingPathComponent("examples/before-after.diff.json")))
    }
    @MainActor
    func testPrepareCompareExportKeepsCurrentReportAndRawLibraryBytes() async throws {
        let (root, before, after, diff) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library"))
        let old = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { _ in before }, batchHistory: history)
        let new = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { _ in after }, batchHistory: history)
        let oldInput = root.appendingPathComponent("old.input"), newInput = root.appendingPathComponent("new.input")
        try Data().write(to: oldInput); try Data().write(to: newInput)
        old.startBatch([oldInput]); try await settle(old); new.startBatch([newInput]); try await settle(new)
        let oldSnapshot = try XCTUnwrap(old.batchSnapshot), newSnapshot = try XCTUnwrap(new.batchSnapshot)
        let workspace = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchHistory: history, batchCompare: { baseline, current in
            XCTAssertEqual(baseline, before); XCTAssertEqual(current, after); return diff
        })
        workspace.importReport(project.appendingPathComponent("examples/mixed.audit.json")); try await settle(workspace)
        let currentIdentity = workspace.report?.image.sliceSHA256
        workspace.prepareBatchComparison(baseline: oldSnapshot.id, current: newSnapshot.id); try await settle(workspace)
        let plan = try XCTUnwrap(workspace.batchComparisonPlan); XCTAssertTrue(plan.suggestions.isEmpty)
        workspace.compareSavedBatches([BatchImagePair(baselineID: oldSnapshot.items[0].id, currentID: newSnapshot.items[0].id)]); try await settle(workspace)
        let result = try XCTUnwrap(workspace.batchComparisonResult)
        XCTAssertEqual(result.rows.first?.state, "compared"); XCTAssertEqual(result.rows.first?.comparison?.summary.changedCount, 2)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, currentIdentity)
        let retained = try await library.load(XCTUnwrap(oldSnapshot.items[0].retainedReportID)); XCTAssertEqual(retained.data, before)
        let output = root.appendingPathComponent("comparison.json")
        workspace.exportJSON(try result.exportData(), to: output); try await settle(workspace)
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(exported["report_kind"] as? String, "airs.batch_comparison")
        // The drill-down carries the same original-input protection as aggregate export.
        let document = ComparisonDocument(report: try ComparisonReport.decode(diff), data: diff,
            formattedJSON: "", protectedInputs: [oldInput, newInput])
        XCTAssertThrowsError(try workspace.validateExportDestination(newInput, protectedInputs: document.protectedInputs))
        let app = root.appendingPathComponent("Owned.app")
        XCTAssertThrowsError(try workspace.validateExportDestination(app.appendingPathComponent("Contents/report.json"), protectedInputs: [app]))
        XCTAssertNoThrow(try workspace.validateExportDestination(output, protectedInputs: document.protectedInputs))
    }
    @MainActor
    func testChangedCheckpointRefusesComparisonAndCancellationRetainsCompletedRows() async throws {
        let (root, before, after, diff) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library"))
        let old = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { _ in before }, batchHistory: history)
        let new = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { _ in after }, batchHistory: history)
        let inputs = (0..<4).map { root.appendingPathComponent("\($0).input") }
        for input in inputs { try Data().write(to: input) }
        old.startBatch(Array(inputs.prefix(2))); try await settle(old)
        new.startBatch(Array(inputs.suffix(2))); try await settle(new)
        let baseline = try XCTUnwrap(old.batchSnapshot), current = try XCTUnwrap(new.batchSnapshot)
        let workspace = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchHistory: history, batchCompare: { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000); return diff
        })
        workspace.prepareBatchComparison(baseline: baseline.id, current: current.id); try await settle(workspace)
        _ = try await history.save(baseline)
        let pairs = zip(baseline.items, current.items).map { BatchImagePair(baselineID: $0.id, currentID: $1.id) }
        workspace.compareSavedBatches(pairs); try await settle(workspace)
        XCTAssertTrue(workspace.showingError); XCTAssertNil(workspace.batchComparisonResult)
        workspace.showingError = false
        workspace.prepareBatchComparison(baseline: baseline.id, current: current.id); try await settle(workspace)
        workspace.compareSavedBatches(pairs)
        for _ in 0..<200 { if workspace.batchComparisonResult != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        workspace.cancel(); try await settle(workspace)
        XCTAssertTrue(try XCTUnwrap(workspace.batchComparisonResult).cancelled)
        XCTAssertEqual(workspace.batchComparisonResult?.rows.map(\.state), ["not_compared", "not_compared"])
        XCTAssertFalse(workspace.isBusy)
    }
    @MainActor
    func testNewSavedBatchStoreReopensForNativePairingSeed() async throws {
        // Deliberately retained, owned UI seed. This never audits or executes inputs.
        let root = project.appendingPathComponent("build/batch-comparison-evidence/ui-seed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library"))
        let before = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json")), after = try Data(contentsOf: project.appendingPathComponent("examples/after.audit.json"))
        let old = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { input in
            if input.lastPathComponent == "baseline-failed.input" { throw CocoaError(.fileReadUnknown) }; return before
        }, batchHistory: history)
        let new = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchAudit: { input in
            if input.lastPathComponent == "current-cancelled.input" { throw CancellationError() }; return after
        }, batchHistory: history)
        let oldInputs = ["baseline-completed.input", "baseline-failed.input"].map { root.appendingPathComponent($0) }
        let newInputs = ["current-completed.input", "current-cancelled.input"].map { root.appendingPathComponent($0) }
        for input in oldInputs + newInputs { try Data("Owned placeholder; never executed".utf8).write(to: input) }
        old.startBatch(oldInputs); try await settle(old); new.startBatch(newInputs); try await settle(new)
        let baseline = try XCTUnwrap(old.batchSnapshot), current = try XCTUnwrap(new.batchSnapshot)
        let reopened = AuditWorkspace(library: library, recents: BatchComparisonRecents(), batchHistory: BatchHistory(root: root.appendingPathComponent("history")))
        reopened.prepareBatchComparison(baseline: baseline.id, current: current.id); try await settle(reopened)
        XCTAssertEqual(reopened.batchComparisonPlan?.baseline.items.map(\.status), [.completed, .failed])
        XCTAssertEqual(reopened.batchComparisonPlan?.current.items.map(\.status), [.completed, .cancelled])
        let receipt: [String: Any] = ["baseline_batch_id": baseline.id.uuidString, "current_batch_id": current.id.uuidString,
            "library_ids": (baseline.items + current.items).compactMap { $0.retainedReportID?.uuidString }]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("seed.json"))
    }

}
