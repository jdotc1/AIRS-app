import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class DecodeAuditWorkspaceTests:XCTestCase {
    func input() throws -> (DecodeInventory,Data,URL) {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AIRSCoreTests/Fixtures/audit-v1.json")
        let bytes=try Data(contentsOf:fixture),report=try AuditReport.decode(bytes)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        var image=try XCTUnwrap(object["image"] as? [String:Any]);image["file_type"]=2
        let fn=try XCTUnwrap((object["findings"] as? [[String:Any]])?.first?["function"] as? [String:Any])
        let wire:[String:Any] = ["schema_version":1,"report_kind":"airs.decode_inventory","decoder_model":report.generator.analysisModelVersion,"status":"partial","address_space":"preferred_vm","image":image,
            "analysis_config":["limits":["max_functions":1,"max_instructions_per_function":0,"max_total_instructions":0,"max_evidence_per_function":0,"max_total_evidence":0]],
            "functions":[["function":fn,"scan_status":"partial_total_budget","word_scan_complete":false,"blockers_complete":false,"observed_word_count":0,"decoder_admitted_word_count":0,"decline_count":0,"omitted_decline_count":0,"blockers":[]]],
            "summary":["function_count":1,"fully_scanned_function_count":0,"observed_word_count":0,"decoder_admitted_word_count":0,"decline_count":0,"retained_blocker_count":0,"omitted_decline_count":0],"reasons":[],"issues":[],"limitations":["New navigation test data."]]
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-decoder-audit-navigation-20261021-inputs", isDirectory: true).path)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent(UUID().uuidString+".json");try bytes.write(to:url)
        return (try DecodeInventory.decode(JSONSerialization.data(withJSONObject:wire)),bytes,url)
    }
    @MainActor
    func testMatchingSavedAuditSelectsOriginalFindingWithoutRunningAnalysis() async throws {
        let (inventory,_,url)=try input();defer {try? FileManager.default.removeItem(at:url)}
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation()
        owner.decodeInventoryReview=DecodeInventorySession(inventory:inventory,sourceURL:url);navigation.showsEntitlements=true
        await owner.openDecodeAudit(inventory.functions[0].id,source:url,audit:audit,entitlements:entitlements,navigation:navigation)?.value
        XCTAssertNil(owner.decodeInventoryReview);XCTAssertFalse(navigation.showsEntitlements)
        XCTAssertEqual(audit.selectedFinding?.checkedPCs,["0x10000100c"])
        XCTAssertEqual(audit.report?.summary.functionCount,3);XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testMismatchKeepsExistingAuditAndInventoryWithVisibleStatus() async throws {
        let (inventory,bytes,url)=try input();defer {try? FileManager.default.removeItem(at:url)}
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation()
        audit.openValidatedReport(try AuditReport.decode(bytes),data:bytes,from:url)
        let revision=audit.reportRevision
        owner.decodeInventoryReview=DecodeInventorySession(inventory:inventory,sourceURL:url)
        try Data("{}".utf8).write(to:url)
        await owner.openDecodeAudit(inventory.functions[0].id,source:url,audit:audit,entitlements:entitlements,navigation:navigation)?.value
        XCTAssertNotNil(owner.decodeInventoryReview);XCTAssertEqual(audit.reportRevision,revision)
        XCTAssertTrue(owner.status.contains("unavailable"));XCTAssertTrue(owner.blocksActions)
    }
    @MainActor
    func testQuitDuringSavedResolutionPreventsLateAuditReplacement() async throws {
        let (inventory,_,url)=try input();defer {try? FileManager.default.removeItem(at:url)}
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation(),revision=audit.reportRevision
        owner.decodeInventoryReview=DecodeInventorySession(inventory:inventory,sourceURL:url)
        let job=owner.openDecodeAudit(inventory.functions[0].id,source:url,audit:audit,entitlements:entitlements,navigation:navigation)
        let settled=await owner.finishBeforeQuit();await job?.value
        XCTAssertTrue(settled);XCTAssertNil(audit.report);XCTAssertEqual(audit.reportRevision,revision)
        XCTAssertNil(owner.decodeInventoryReview);XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testChangedAuditRevisionDiscardsCompletedResolution() async throws {
        let (inventory,bytes,url)=try input();defer {try? FileManager.default.removeItem(at:url)}
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation()
        owner.decodeInventoryReview=DecodeInventorySession(inventory:inventory,sourceURL:url)
        let job=owner.openDecodeAudit(inventory.functions[0].id,source:url,audit:audit,entitlements:entitlements,navigation:navigation)
        audit.openValidatedReport(try AuditReport.decode(bytes),data:bytes,from:url)
        let revision=audit.reportRevision
        await job?.value
        XCTAssertEqual(audit.reportRevision,revision);XCTAssertNotNil(owner.decodeInventoryReview)
        XCTAssertTrue(owner.status.contains("Workspace changed"))
    }
}
