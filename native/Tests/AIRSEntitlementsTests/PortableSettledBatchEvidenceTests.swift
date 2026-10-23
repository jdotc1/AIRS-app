import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

/// Source-first selectors: deliberately UNRUN until the machine gate is granted.
final class PortableSettledBatchEvidenceTests: XCTestCase {
    private func fixture() throws -> (InspectionProject, UUID, Data) {
        let historyID = UUID()
        let row = EntitlementBatchRow(pair: .init(previous: URL(fileURLWithPath: "/missing/Before.app"),
            current: URL(fileURLWithPath: "/missing/After.app"), architecture: .arm64),
            status: .completed, message: "Original outcome", changedCount: 2, unchangedCount: 3, retainedReportID: UUID())
        let cancelled = EntitlementBatchRow(pair: .init(previous: URL(fileURLWithPath: "/missing/A.app"),
            current: URL(fileURLWithPath: "/missing/B.app"), architecture: .arm64), status: .cancelled, message: "Cancelled")
        let record = try EntitlementBatchRecord(result: .init(id: UUID(), rows: [row, cancelled], settled: true, cancelled: true))
        // Noncanonical whitespace must survive transport too.
        let bytes = Data(" \n".utf8) + (try record.data()) + Data("\n".utf8)
        var project = InspectionProject(name: "Historical outcomes")
        project.batchLinks = [.init(family: .entitlements, historyID: historyID, rowIDs: [row.id, cancelled.id])]
        return (project, historyID, bytes)
    }
    func testSettledMixedOutcomeBytesAndMissingReportRemainExplicit() throws {
        let (project, id, bytes) = try fixture()
        let history = try PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes])
        let decoded = try PortableSettledBatchEvidence.decode(history.originalBytes, project: project)
        XCTAssertEqual(decoded.outcomes[0].rows.map(\.status), [.completed, .cancelled])
        XCTAssertEqual(decoded.outcomes[0].cancelled, true)
        XCTAssertTrue(decoded.outcomes[0].rows.allSatisfy { !$0.reportIncluded })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: history.originalBytes) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(entries[0]["record"] as? String)), bytes)
    }
    func testMissingUnsettledIncompleteAndAuditLinksStayExplicit() throws {
        var (project, id, _) = try fixture()
        project.batchLinks.append(.init(family: .audit, historyID: UUID(), rowIDs: [UUID()]))
        for reason in [PortableBatchAbsence.missing, .unsettled, .incomplete] {
            let value = try PortableSettledBatchEvidence.prepare(project: project, records: [:], unavailable: [id: reason])
            XCTAssertEqual(value.outcomes[0].absence, reason)
            XCTAssertEqual(value.outcomes[1].absence, .unsupportedFamily)
            XCTAssertTrue(value.outcomes.allSatisfy { $0.rows.isEmpty })
        }
    }
    func testUnsettledPayloadWrongRowsExtraHistoryAndForeignProjectDecline() throws {
        let (project, id, bytes) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any]); result["settled"] = false; object["result"] = result
        XCTAssertThrowsError(try PortableSettledBatchEvidence.prepare(project: project, records: [id: JSONSerialization.data(withJSONObject: object)]))
        XCTAssertThrowsError(try PortableSettledBatchEvidence.prepare(project: project, records: [UUID(): bytes]))
        var wrong = project; wrong.batchLinks = [.init(family: .entitlements, historyID: id, rowIDs: [UUID()])]
        XCTAssertThrowsError(try PortableSettledBatchEvidence.prepare(project: wrong, records: [id: bytes]))
        let value = try PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes])
        XCTAssertThrowsError(try PortableSettledBatchEvidence.decode(value.originalBytes, project: InspectionProject(name: "Foreign")))
        XCTAssertThrowsError(try PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes], unavailable: [id: .missing]))
    }
    func testCompanionReconstructionWithoutSourceAndExactChildPreservation() async throws {
        let helper = PortableProjectTests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, id, bytes) = try fixture()
        let child = root.appendingPathComponent("original.airsproject")
        let metadata = Data("\n".utf8) + (try project.data())
        try PortableProjectWriter.write(project: project, metadata: metadata, evidence: [:], to: child)
        let admission = try PortableProjectReader.prepare(at: child)
        let history = try PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes])
        let wrapper = root.appendingPathComponent("historical")
        try PortableSettledBatchProject.write(admission, history: history, to: wrapper)
        XCTAssertEqual(try Data(contentsOf: wrapper.appendingPathComponent("project.airsproject/manifest.json")), admission.manifestBytes)
        XCTAssertEqual(try Data(contentsOf: wrapper.appendingPathComponent("project.airsproject/project.json")), metadata)
        XCTAssertThrowsError(try PortableSettledBatchProject.write(admission, history: history, to: wrapper))
        try FileManager.default.removeItem(at: child)
        let prepared = try PortableSettledBatchProject.prepare(at: wrapper)
        let recipient = root.appendingPathComponent("recipient")
        let store = try await PortableSettledBatchProject.reconstruct(prepared, to: recipient)
        do { _ = try await PortableSettledBatchProject.reconstruct(prepared, to: recipient); XCTFail("Existing target") } catch {}
        let restored = try await store.load(project.id)
        let review = try PortableSettledBatchProject.history(in: recipient, project: restored)
        XCTAssertEqual(review.originalBytes, history.originalBytes)
        XCTAssertEqual(review.outcomes[0].rows.count, 2)
        XCTAssertEqual(restored.batchLinks, project.batchLinks)
        // Legacy export stays schema 1 and does not silently claim the companion.
        let legacy = root.appendingPathComponent("legacy.airsproject")
        try await store.exportPortableProject(project.id, to: legacy)
        XCTAssertEqual(try PortableProjectReader.inventory(at: legacy).schemaVersion, 1)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("project.json")), metadata)
    }
    func testChangedPreviewAndInjectedFailurePublishNothing() async throws {
        let helper = PortableProjectTests(), root = try helper.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, id, bytes) = try fixture()
        let child = root.appendingPathComponent("child")
        try PortableProjectWriter.write(project: project, metadata: project.data(), evidence: [:], to: child)
        let wrapper = root.appendingPathComponent("wrapper")
        try PortableSettledBatchProject.write(PortableProjectReader.prepare(at: child),
            history: PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes]), to: wrapper)
        let admitted = try PortableSettledBatchProject.prepare(at: wrapper)
        let destination = root.appendingPathComponent("failed")
        do {
            _ = try await PortableSettledBatchProject.reconstruct(admitted, to: destination, beforePublish: { throw CancellationError() })
            XCTFail("Injected cancellation")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try Data("changed".utf8).write(to: wrapper.appendingPathComponent("settled-batches.json"))
        do { _ = try await PortableSettledBatchProject.reconstruct(admitted, to: destination); XCTFail("Stale preview") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".airsproject-") })
    }
    func testEnvelopeCapacityUnknownKeysAndContradictoryHistoryDecline() throws {
        var (project, id, bytes) = try fixture()
        project.batchLinks.append(.init(family: .entitlements, historyID: id, rowIDs: []))
        let history = try PortableSettledBatchEvidence.prepare(project: project, records: [id: bytes])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: history.originalBytes) as? [String: Any])
        object["unexpected"] = true
        XCTAssertThrowsError(try PortableSettledBatchEvidence.decode(JSONSerialization.data(withJSONObject: object), project: project))
        object.removeValue(forKey: "unexpected")
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[1].removeValue(forKey: "record"); entries[1]["absence"] = "missing"; object["entries"] = entries
        XCTAssertThrowsError(try PortableSettledBatchEvidence.decode(JSONSerialization.data(withJSONObject: object), project: project))
        XCTAssertThrowsError(try PortableSettledBatchEvidence.decode(Data(repeating: 32, count: PortableSettledBatchEvidence.maximumBytes + 1), project: project))
    }

}
