import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class PolicyWorkspaceTests:XCTestCase {
    func folder() throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-policy-workspace-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    func request(_ root:URL) throws -> URL {
        let scope=InventoryScope(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[])
        func inventory()->ComponentInventory {.init(scope:scope,components:[.init(relativePath:"Contents/MacOS/Owned",kind:"app",architectures:["arm64"])])}
        let review=try ComponentComparison.review(previous:inventory(),current:inventory(),architecture:.arm64,entitlementResults:[])
        try ComponentReviewArchive.encode(review).write(to:root.appendingPathComponent("review.airsreview"))
        try ReviewPolicy(rules:[.init(check:.requiredArchitectures,componentRelativePath:"Contents/MacOS/Owned",architecture:"arm64")]).data().write(to:root.appendingPathComponent("policy.json"))
        let object:[String:Any]=["kind":"airs.review-policy-request","schemaVersion":1,"evaluationID":UUID().uuidString,"mode":"historicalRecord","reviewArchive":"review.airsreview","policy":"policy.json","expectedReviewDigest":try ReviewPolicy.reviewDigest(review),"expectedContentIdentities":[String:String](),"assessments":[String]()]
        let url=root.appendingPathComponent("request.json");try JSONSerialization.data(withJSONObject:object).write(to:url);return url
    }
    @MainActor
    func testExplicitEvaluationUsesCLIBytesAndProtectsInputsAndSessions() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let url=try request(root),command=try ReviewPolicyCommand(arguments:["--request",url.path])
        let expected=try await command.run(),owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(),revision=audit.reportRevision
        await owner.openPolicyReview(url,audit:audit,entitlements:entitlements)?.value
        XCTAssertNil(owner.policyReview?.result);XCTAssertTrue(owner.blocksActions)
        owner.evaluatePolicyReview()
        XCTAssertEqual(try owner.policyReview?.result?.data(),expected.standardOutput)
        XCTAssertEqual(audit.reportRevision,revision);XCTAssertNil(audit.report)
        let original=try Data(contentsOf:url)
        await owner.exportInventory(to:url,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(try Data(contentsOf:url),original)
        let output=root.appendingPathComponent("result.json")
        await owner.exportInventory(to:output,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(try Data(contentsOf:output),expected.standardOutput)
        owner.closePolicyReview();XCTAssertNil(owner.policyReview)
    }
    @MainActor
    func testInvalidRequestAndQuitDoNotPublishLatePolicyReview() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let url=try request(root),owner=AIRSFileOpen(hasModal:{false}),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        let task=owner.openPolicyReview(url,audit:audit,entitlements:entitlements)
        let allowed=await owner.finishBeforeQuit();XCTAssertTrue(allowed);await task?.value
        XCTAssertNil(owner.policyReview);XCTAssertFalse(owner.isBusy)
        let next=AIRSFileOpen(hasModal:{false});try Data("bad".utf8).write(to:url)
        await next.openPolicyReview(url,audit:audit,entitlements:entitlements)?.value
        XCTAssertNil(next.policyReview);XCTAssertNil(audit.report)
    }
}
