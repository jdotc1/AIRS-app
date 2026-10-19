import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

private actor PortableHostReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1; return ExampleSnapshots.pair(architecture: architecture).previous
    }
}
final class PortableEntitlementManifestWorkspaceTests: XCTestCase {
    @MainActor
    func testExplicitRelativeExportAndRelocatedReviewPreservePrimaryUntilAdoption() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/portable-manifest-evidence/host/\(UUID().uuidString)")
        let original = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = PortableHostReader()
        let workspace = EntitlementsWorkspace(reader: reader)
        workspace.loadExample(); let primary = workspace.model.reportRevision
        workspace.addBatchPair(previous: original.appendingPathComponent("Before.app", isDirectory: true),
            current: original.appendingPathComponent("After.app", isDirectory: true), architecture: .arm64)
        let originalIDs = workspace.batchPairs.map(\.id)
        let output = original.appendingPathComponent("portable.json")
        await workspace.exportBatchManifest(to: output, relativePaths: true)?.value
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(try EntitlementBatchManifest.read(output).version, 2)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let source = moved.appendingPathComponent("portable.json")
        await workspace.openBatchManifest(source)?.value
        let review = try XCTUnwrap(workspace.batchManifestReview)
        XCTAssertTrue(review.usesRelativePaths)
        XCTAssertEqual(review.pairs[0].previous.path, moved.appendingPathComponent("Before.app").path)
        XCTAssertEqual(workspace.batchPairs.map(\.id), originalIDs)
        XCTAssertEqual(workspace.model.reportRevision, primary)
        workspace.adoptBatchManifest(review.id)
        XCTAssertEqual(workspace.batchPairs.map(\.id), review.pairs.map(\.id))
        XCTAssertNil(workspace.batchResult); XCTAssertNil(workspace.batchCheckpoint)
        await workspace.exportBatchManifest(to: source, relativePaths: true)?.value
        XCTAssertNotNil(workspace.errorMessage)
        workspace.errorMessage = nil
        let invalid = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        let invalidOutput = invalid.appendingPathComponent("must-not-write.json")
        await workspace.exportBatchManifest(to: invalidOutput, relativePaths: true)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))
        XCTAssertEqual(workspace.model.reportRevision, primary)
        let calls = await reader.calls; XCTAssertEqual(calls, 0)
    }
}
