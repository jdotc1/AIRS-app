import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

/// Source-only recipient re-export boundaries; all methods remain UNRUN.
final class PortableSettledBatchReexportTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let project: PortableProjectAdmission
        let recipient: URL
        let historyBytes: Data
    }

    private func fixture() async throws -> Fixture {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? checkout.appendingPathComponent("build/settled-batch-reexport")
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceRoot = root.appendingPathComponent("source"), store = InspectionProjectStore(root: sourceRoot)
        let historyRoot = root.appendingPathComponent("live-history"), history = EntitlementBatchHistory(root: historyRoot)
        let row = EntitlementBatchRow(pair: .init(previous: URL(fileURLWithPath: "/missing/Before.app"),
            current: URL(fileURLWithPath: "/missing/After.app"), architecture: .arm64), status: .completed,
            message: "Original settled result", changedCount: 1, unchangedCount: 2, retainedReportID: UUID())
        let record = try EntitlementBatchRecord(result: .init(id: UUID(), rows: [row], settled: true, cancelled: false))
        let recordBytes = Data("\n ".utf8) + (try record.data())
        let historyID = try await history.keep(recordBytes)
        var project = try await store.create(name: "Recipient re-export")
        project = try await store.addEvidence(PortableProjectTests().evidence(), to: project.id)
        project = try await store.pinBaseline(project.evidence[0].id, in: project.id)
        project = try await store.addAnnotation("Retain this review note", acknowledged: true, to: project.id)
        project = try await store.linkBatch(.init(family: .entitlements, historyID: historyID, rowIDs: [row.id]), to: project.id)
        let metadata = Data(" \n".utf8) + (try project.data())
        try metadata.write(to: sourceRoot.appendingPathComponent("Projects/" + project.id.uuidString + "/manifest.json"))
        let captured = try await PortableSettledBatchEvidence.prepare(project: project, history: history)
        let child = root.appendingPathComponent("admitted.airsproject")
        try await store.exportPortableProject(project.id, to: child)
        let manifestURL = child.appendingPathComponent("manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        try (Data("\n ".utf8) + manifest + Data("\n".utf8)).write(to: manifestURL)
        let admission = try PortableProjectReader.prepare(at: child)
        let companion = root.appendingPathComponent("original-companion")
        try PortableSettledBatchProject.write(admission, history: captured, to: companion)
        let recipient = root.appendingPathComponent("recipient")
        _ = try await PortableSettledBatchProject.reconstruct(PortableSettledBatchProject.prepare(at: companion), to: recipient)
        try FileManager.default.removeItem(at: sourceRoot)
        try FileManager.default.removeItem(at: historyRoot)
        try FileManager.default.removeItem(at: companion)
        return Fixture(root: root, project: admission, recipient: recipient, historyBytes: captured.originalBytes)
    }

    func testRecipientReexportPreservesExactProjectEvidenceAndHistoryAcrossAnotherRecipient() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient)
        XCTAssertEqual(prepared.history.originalBytes, fixture.historyBytes)
        let output = fixture.root.appendingPathComponent("reexport")
        try prepared.write(to: output)
        let admitted = try PortableSettledBatchProject.prepare(at: output)
        XCTAssertEqual(admitted.project.projectBytes, fixture.project.projectBytes)
        XCTAssertEqual(admitted.project.manifestBytes, fixture.project.manifestBytes)
        XCTAssertEqual(admitted.history.originalBytes, fixture.historyBytes)
        for entry in admitted.project.inventory.evidence {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("project.airsproject/" + entry.path)),
                           try Data(contentsOf: fixture.project.packageURL.appendingPathComponent(entry.path)))
        }
        let second = fixture.root.appendingPathComponent("second-recipient")
        let store = try await PortableSettledBatchProject.reconstruct(admitted, to: second)
        let restored = try await store.load(fixture.project.project.id)
        XCTAssertEqual(restored.batchLinks, fixture.project.project.batchLinks)
        XCTAssertEqual(restored.annotations, fixture.project.project.annotations)
        XCTAssertEqual(restored.pinnedBaselineID, fixture.project.project.pinnedBaselineID)
        let again = fixture.root.appendingPathComponent("second-reexport")
        try PortableSettledBatchReexport.prepare(project: admitted.project, recipientStore: second).write(to: again)
        XCTAssertEqual(try Data(contentsOf: again.appendingPathComponent("settled-batches.json")), fixture.historyBytes)
        XCTAssertTrue(admitted.history.outcomes[0].rows.allSatisfy { !$0.reportIncluded })
    }

    func testMissingHistoryAndMismatchedRecipientMetadataDeclineWithoutFallback() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sidecar = fixture.recipient.appendingPathComponent("settled-batches.json")
        try FileManager.default.removeItem(at: sidecar)
        XCTAssertThrowsError(try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient))
        try fixture.historyBytes.write(to: sidecar)
        let metadata = fixture.recipient.appendingPathComponent("Projects/" + fixture.project.project.id.uuidString + "/manifest.json")
        try (fixture.project.projectBytes + Data("\n".utf8)).write(to: metadata)
        XCTAssertThrowsError(try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient),
                             "Even equivalent reformatted metadata is not the exact admitted snapshot")
    }

    func testHistoryChangedAfterPreviewAndMetadataChangedBeforePublicationDecline() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient)
        let sidecar = fixture.recipient.appendingPathComponent("settled-batches.json")
        try (fixture.historyBytes + Data("\n".utf8)).write(to: sidecar)
        let output = fixture.root.appendingPathComponent("stale")
        XCTAssertThrowsError(try prepared.write(to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try fixture.historyBytes.write(to: sidecar)
        let current = try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient)
        let metadata = fixture.recipient.appendingPathComponent("Projects/" + fixture.project.project.id.uuidString + "/manifest.json")
        let changed = fixture.project.projectBytes + Data("\n".utf8)
        XCTAssertThrowsError(try current.write(to: output, beforePublish: { try changed.write(to: metadata) }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".airsproject-") })
    }

    func testExistingDestinationCancellationAndProtectedRecipientRemainIntact() async throws {
        let fixture = try await fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try PortableSettledBatchReexport.prepare(project: fixture.project, recipientStore: fixture.recipient)
        let existing = fixture.root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep"); try Data("original".utf8).write(to: sentinel)
        XCTAssertThrowsError(try prepared.write(to: existing))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))
        XCTAssertThrowsError(try prepared.write(to: fixture.recipient.appendingPathComponent("nested-export")))
        XCTAssertThrowsError(try prepared.write(to: fixture.project.packageURL.appendingPathComponent("nested-export")))
        let cancelled = fixture.root.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try prepared.write(to: cancelled, beforePublish: { throw CancellationError() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertEqual(try Data(contentsOf: fixture.recipient.appendingPathComponent("settled-batches.json")), fixture.historyBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".airsproject-") })
    }
}
