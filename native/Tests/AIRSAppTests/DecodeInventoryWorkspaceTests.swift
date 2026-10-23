import XCTest
import AIRSEntitlements
@testable import AIRSApp

final class DecodeInventoryWorkspaceTests: XCTestCase {
    func source() throws -> URL {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-native-decode-inventory-20261021-workspace-inputs", isDirectory: true).path)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent(UUID().uuidString+".json")
        let wire:[String:Any] = ["schema_version":1,"report_kind":"airs.decode_inventory","decoder_model":"owned-empty-model","status":"no_functions","address_space":"preferred_vm",
            "analysis_config":["limits":["max_functions":1,"max_instructions_per_function":8,"max_total_instructions":8,"max_evidence_per_function":2,"max_total_evidence":2]],
            "image":["display_name":"owned-empty","container_sha256":String(repeating:"1",count:64),"slice_sha256":String(repeating:"2",count:64),"architecture":"arm64","cpu_subtype":0,"uuid":NSNull(),"slice_offset":0,"slice_size":128,"preferred_base":"0x1000","file_type":6],
            "summary":["function_count":0,"fully_scanned_function_count":0,"observed_word_count":0,"decoder_admitted_word_count":0,"decline_count":0,"retained_blocker_count":0,"omitted_decline_count":0],
            "functions":[],"reasons":[],"issues":[],"limitations":["No functions observed."]]
        try JSONSerialization.data(withJSONObject:wire).write(to:url)
        return url
    }
    @MainActor
    func testSavedReviewPreservesAuditAndBlocksCompetingOpenUntilClosed() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        let revision=audit.reportRevision,url=try source()
        defer {try? FileManager.default.removeItem(at:url)}
        await owner.openDecodeInventory(url,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(owner.decodeInventoryReview?.inventory.status,"no_functions")
        XCTAssertTrue(owner.blocksActions);XCTAssertFalse(owner.isBusy)
        XCTAssertEqual(audit.reportRevision,revision);XCTAssertNil(audit.report)
        XCTAssertNil(owner.openDecodeInventory(url,audit:audit,entitlements:entitlements))
        owner.closeDecodeInventory()
        XCTAssertFalse(owner.blocksActions)
    }
    @MainActor
    func testQuitSettlesReadAndPreventsLateReviewPublication() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),url=try source()
        defer {try? FileManager.default.removeItem(at:url)}
        let job=owner.openDecodeInventory(url,audit:audit,entitlements:entitlements)
        let settled=await owner.finishBeforeQuit();await job?.value
        XCTAssertTrue(settled);XCTAssertNil(owner.decodeInventoryReview);XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testInvalidSavedInventoryCannotPublishOrReplaceAudit() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),url=try source()
        defer {try? FileManager.default.removeItem(at:url)}
        try Data("{}".utf8).write(to:url)
        let revision=audit.reportRevision
        await owner.openDecodeInventory(url,audit:audit,entitlements:entitlements)?.value
        XCTAssertNil(owner.decodeInventoryReview);XCTAssertNil(audit.report);XCTAssertEqual(audit.reportRevision,revision)
        XCTAssertTrue(owner.blocksActions);XCTAssertTrue(owner.status.contains("unavailable"))
        XCTAssertNotNil(owner.decodeInventoryError)
        let settledStatus=owner.status
        owner.dismissDecodeInventoryError()
        XCTAssertNil(owner.decodeInventoryError);XCTAssertFalse(owner.blocksActions)
        XCTAssertEqual(owner.status,settledStatus)
        XCTAssertEqual(audit.reportRevision,revision)
    }
    @MainActor
    func testQuitDuringInvalidReadDoesNotPublishErrorAlert() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),url=try source()
        defer {try? FileManager.default.removeItem(at:url)}
        try Data("{}".utf8).write(to:url)
        let job=owner.openDecodeInventory(url,audit:audit,entitlements:entitlements)
        let settled=await owner.finishBeforeQuit();await job?.value
        XCTAssertTrue(settled);XCTAssertNil(owner.decodeInventoryError);XCTAssertNil(owner.decodeInventoryReview)
    }

}
