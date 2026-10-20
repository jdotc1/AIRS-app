import XCTest
import AIRSEntitlements
@testable import AIRSApp
final class CoverageWorkspaceTests:XCTestCase {
    var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/coverage")}
    @MainActor
    func testInventoryStagesWithoutChangingSessionsAndSourceSelectsReferencedFinding() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation(),revision=audit.reportRevision
        navigation.showsEntitlements=true
        await owner.openCoverage(root.appendingPathComponent("single.json"),audit:audit,entitlements:entitlements)?.value
        XCTAssertNotNil(owner.coverageReview);XCTAssertTrue(owner.blocksActions);XCTAssertEqual(audit.reportRevision,revision);XCTAssertNil(audit.report)
        let inventory=try XCTUnwrap(owner.coverageReview?.inventory),reason=try XCTUnwrap(inventory.reasons.first),example=try XCTUnwrap(reason.examples.first)
        await owner.openCoverageObservation(example,reason:reason.reason,source:root.appendingPathComponent("source.audit.json"),audit:audit,entitlements:entitlements,navigation:navigation)?.value
        XCTAssertNil(owner.coverageReview);XCTAssertEqual(audit.selectedFinding?.id,example.finding_id);XCTAssertFalse(navigation.showsEntitlements)
    }
    @MainActor
    func testInvalidObservationPreservesCoverageAndAuditAndQuitPreventsLatePublication() async throws {
        let owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),navigation=AIRSNavigation(),revision=audit.reportRevision
        await owner.openCoverage(root.appendingPathComponent("single.json"),audit:audit,entitlements:entitlements)?.value
        let inventory=try XCTUnwrap(owner.coverageReview?.inventory),reason=try XCTUnwrap(inventory.reasons.first),example=try XCTUnwrap(reason.examples.first)
        await owner.openCoverageObservation(example,reason:reason.reason,source:root.appendingPathComponent("unicode-source.audit.json"),audit:audit,entitlements:entitlements,navigation:navigation)?.value
        XCTAssertNotNil(owner.coverageReview);XCTAssertEqual(audit.reportRevision,revision);XCTAssertNil(audit.report)
        owner.closeCoverage()
        let job=owner.openCoverage(root.appendingPathComponent("single.json"),audit:audit,entitlements:entitlements)
        let canQuit=await owner.finishBeforeQuit();await job?.value
        XCTAssertTrue(canQuit);XCTAssertNil(owner.coverageReview);XCTAssertFalse(owner.isBusy)
    }
}
