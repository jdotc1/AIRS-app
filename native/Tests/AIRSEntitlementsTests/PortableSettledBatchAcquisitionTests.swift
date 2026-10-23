import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

/// New source-only selectors. No execution receipt is claimed for this increment.
final class PortableSettledBatchAcquisitionTests: XCTestCase {
    private func root() throws -> URL {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? checkout.appendingPathComponent("build/settled-batch-acquisition")
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func record() throws -> (EntitlementBatchRecord, Data) {
        let completed = EntitlementBatchRow(pair: .init(previous: URL(fileURLWithPath: "/absent/Previous.app"),
            current: URL(fileURLWithPath: "/absent/Current.app"), architecture: .arm64),
            status: .completed, message: "Retained completed outcome", changedCount: 2, unchangedCount: 4,
            retainedReportID: UUID())
        let cancelled = EntitlementBatchRow(pair: .init(previous: URL(fileURLWithPath: "/absent/OtherPrevious.app"),
            current: URL(fileURLWithPath: "/absent/OtherCurrent.app"), architecture: .x86_64),
            status: .cancelled, message: "Original cancelled outcome")
        let record = try EntitlementBatchRecord(result: .init(id: UUID(), rows: [completed, cancelled],
            settled: true, cancelled: true), finishedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return (record, Data(" \n".utf8) + (try record.data()) + Data("\n ".utf8))
    }

    private func embeddedRecords(_ evidence: PortableSettledBatchEvidence) throws -> [Data?] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: evidence.originalBytes) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        return entries.map { ($0["record"] as? String).flatMap { Data(base64Encoded: $0) } }
    }

    func testLibraryIdentitySuppliesExactBytesAcrossRepeatedLinksAndMissingMembership() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let history = EntitlementBatchHistory(root: root.appendingPathComponent("history"))
        let (record, bytes) = try record()
        let historyID = try await history.keep(bytes)
        XCTAssertNotEqual(historyID, record.result.id, "Library identity and batch identity are distinct")
        var project = InspectionProject(name: "Original byte association")
        project.batchLinks = [
            .init(family: .entitlements, historyID: historyID, rowIDs: [record.result.rows[0].id]),
            .init(family: .entitlements, historyID: historyID, rowIDs: []),
            .init(family: .entitlements, historyID: UUID(), rowIDs: [])
        ]
        let captured = try await PortableSettledBatchEvidence.prepare(project: project, history: history)
        XCTAssertEqual(try embeddedRecords(captured), [bytes, bytes, nil])
        XCTAssertEqual(captured.outcomes[0].rows.map(\.id), [record.result.rows[0].id])
        XCTAssertEqual(captured.outcomes[1].rows.map(\.status), [.completed, .cancelled])
        XCTAssertEqual(captured.outcomes[2].absence, .missing)
        XCTAssertEqual(captured.outcomes[1].cancelled, true)
        XCTAssertTrue(captured.outcomes.flatMap(\.rows).allSatisfy { !$0.reportIncluded })
    }

    func testCorruptPresentEntryRejectsInsteadOfBecomingMissing() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history"), history = EntitlementBatchHistory(root: historyRoot)
        let (_, bytes) = try record(), id = try await history.keep(bytes)
        var project = InspectionProject(name: "Corrupt present record")
        project.batchLinks = [.init(family: .entitlements, historyID: id, rowIDs: [])]
        try Data("corrupt".utf8).write(to: historyRoot.appendingPathComponent(id.uuidString + "/report.json"))
        do {
            _ = try await PortableSettledBatchEvidence.prepare(project: project, history: history)
            XCTFail("Present corrupt history must fail; it is not absent")
        } catch {}
    }

    func testUnsettledPresentEntryWithMatchingReceiptStillRejects() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history"), history = EntitlementBatchHistory(root: historyRoot)
        let (_, bytes) = try record(), id = try await history.keep(bytes)
        var project = InspectionProject(name: "Unsettled present record")
        project.batchLinks = [.init(family: .entitlements, historyID: id, rowIDs: [])]
        let folder = historyRoot.appendingPathComponent(id.uuidString)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var result = try XCTUnwrap(object["result"] as? [String: Any]); result["settled"] = false; object["result"] = result
        let unsettled = try JSONSerialization.data(withJSONObject: object)
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("receipt.json"))) as? [String: Any])
        receipt["reportSHA256"] = EntitlementBatchHistory.reportDigest(unsettled)
        try unsettled.write(to: folder.appendingPathComponent("report.json"))
        try JSONSerialization.data(withJSONObject: receipt).write(to: folder.appendingPathComponent("receipt.json"))
        do {
            _ = try await PortableSettledBatchEvidence.prepare(project: project, history: history)
            XCTFail("A receipt does not make an unsettled record portable")
        } catch {}
    }

    func testAcquiredOutcomesReconstructAfterOriginalHistoryIsRemoved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let historyRoot = root.appendingPathComponent("history"), history = EntitlementBatchHistory(root: historyRoot)
        let (record, bytes) = try record(), id = try await history.keep(bytes)
        var project = InspectionProject(name: "Independent recipient")
        project.batchLinks = [.init(family: .entitlements, historyID: id, rowIDs: [])]
        let captured = try await PortableSettledBatchEvidence.prepare(project: project, history: history)
        try FileManager.default.removeItem(at: historyRoot)
        let child = root.appendingPathComponent("child.airsproject"), wrapper = root.appendingPathComponent("companion")
        try PortableProjectWriter.write(project: project, metadata: project.data(), evidence: [:], to: child)
        try PortableSettledBatchProject.write(PortableProjectReader.prepare(at: child), history: captured, to: wrapper)
        try FileManager.default.removeItem(at: child)
        let destination = root.appendingPathComponent("recipient")
        let store = try await PortableSettledBatchProject.reconstruct(PortableSettledBatchProject.prepare(at: wrapper), to: destination)
        let restored = try await store.load(project.id)
        let review = try PortableSettledBatchProject.history(in: destination, project: restored)
        XCTAssertEqual(try embeddedRecords(review), [bytes])
        XCTAssertEqual(review.outcomes[0].batchID, record.result.id)
        XCTAssertEqual(review.outcomes[0].link.historyID, id)
        XCTAssertEqual(review.outcomes[0].rows.map(\.status), [.completed, .cancelled])
    }

    func testAuditOnlyProjectDoesNotReadUnrelatedEntitlementStore() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let notDirectory = root.appendingPathComponent("not-a-store")
        try Data("unrelated".utf8).write(to: notDirectory)
        var project = InspectionProject(name: "Audit history is unsupported")
        project.batchLinks = [.init(family: .audit, historyID: UUID(), rowIDs: [])]
        let captured = try await PortableSettledBatchEvidence.prepare(project: project,
            history: EntitlementBatchHistory(root: notDirectory))
        XCTAssertEqual(captured.outcomes[0].absence, .unsupportedFamily)
        XCTAssertEqual(try Data(contentsOf: notDirectory), Data("unrelated".utf8))
    }

    func testCancelledAcquisitionDoesNotProduceEvidence() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let history = EntitlementBatchHistory(root: root.appendingPathComponent("history"))
        let (_, bytes) = try record(), id = try await history.keep(bytes)
        var project = InspectionProject(name: "Cancelled acquisition")
        project.batchLinks = [.init(family: .entitlements, historyID: id, rowIDs: [])]
        let selected = project
        let task = Task<PortableSettledBatchEvidence, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PortableSettledBatchEvidence.prepare(project: selected, history: history)
        }
        do { _ = try await task.value; XCTFail("Cancelled acquisition") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
}
