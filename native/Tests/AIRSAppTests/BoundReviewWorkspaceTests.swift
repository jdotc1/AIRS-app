import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class BoundReviewWorkspaceTests: XCTestCase {
    @MainActor
    func testUnassociatedReceiptImportAndReloadPreserveAuditSelection() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("AIRS-C4-bound-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("synthetic-ack.json")
        let data = Data("""
        {"report_kind":"airs.macscope_bound_acknowledgment","schema_version":1,"acknowledgment_id":"\(UUID().uuidString)",
        "request":null,"untrusted_request_id":null,"source_report":null,"finding_id":null,
        "consumer":{"bundle_id":"synthetic.consumer","version":"test","build":"1","source_revision":null,"build_provenance_state":"unavailable"},
        "profile":null,"completed_at":"2026-10-20T23:00:00Z","outcome":"rejected","code":"malformed_transport","admission":"not_validated",
        "destination":null,"navigation":null,"semantics":"source_reported_not_consumer_verified","diagnostic":"Synthetic only"}
        """.utf8)
        try data.write(to:file)
        let ledgerRoot = root.appendingPathComponent("ledger")
        let workspace = AuditWorkspace(boundReviewLedger:BoundReviewLedger(root:ledgerRoot))
        let revision = workspace.reportRevision, selection = workspace.selection
        await workspace.importConsumerAcknowledgment(file)?.value
        XCTAssertEqual(workspace.boundReviewReceipts?.count,1)
        XCTAssertEqual(workspace.boundReviewReceipts?.first?.associated,false)
        XCTAssertEqual(workspace.reportRevision,revision); XCTAssertEqual(workspace.selection,selection)
        XCTAssertFalse(workspace.isBusy)
        XCTAssertTrue(workspace.blocksFileOpen,"Receipt review participates in existing modal navigation guard")
        let reopened = AuditWorkspace(boundReviewLedger:BoundReviewLedger(root:ledgerRoot))
        await reopened.reviewConsumerAcknowledgments()?.value
        XCTAssertEqual(reopened.boundReviewReceipts?.count,1)
        XCTAssertEqual(try Data(contentsOf:file),data)
        let bad = root.appendingPathComponent("invalid.json"); try Data("{}".utf8).write(to:bad)
        await reopened.importConsumerAcknowledgment(bad)?.value
        XCTAssertTrue(reopened.showingError)
        XCTAssertEqual(reopened.boundReviewReceipts?.count,1,"Invalid imports must preserve previous evidence")
    }
}
