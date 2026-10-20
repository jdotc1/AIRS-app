import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp
final class AssessmentWorkspaceTests:XCTestCase {
    @MainActor
    func testCaptureRunsNothingExplicitMetadataDoesNotValidateAndReceiptIsReused() async throws {
        let app=try fixture();defer {try? FileManager.default.removeItem(at:app.deletingLastPathComponent())}
        let audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        let owner=AIRSFileOpen(hasModal:{false},assessmentRunner:AssessmentRunner(checker:MetadataOnlyChecker()))
        await owner.buildAssessment(app,audit:audit,entitlements:entitlements)?.value
        let capture=try XCTUnwrap(owner.assessmentReview)
        XCTAssertNotNil(capture.identity)
        XCTAssertTrue(capture.document.results.isEmpty)
        await owner.runAssessment(.signingInformation,audit:audit,entitlements:entitlements)?.value
        let review=try XCTUnwrap(owner.assessmentReview)
        XCTAssertEqual(review.id,capture.id)
        XCTAssertEqual(review.document.outcome(for:.signingInformation),.passed)
        XCTAssertEqual(review.document.outcome(for:.signatureValidity),.notPerformed)
        XCTAssertEqual(review.document.outcome(for:.localDistribution),.notPerformed)
        XCTAssertNil(owner.runAssessment(.signingInformation,audit:audit,entitlements:entitlements))
        XCTAssertNil(owner.exportInventory(to:app.appendingPathComponent("bad.airsreview"),audit:audit,entitlements:entitlements))
    }
    @MainActor
    func testImportedAssessmentArchiveRequiresSelectionAndCannotRunLive() async throws {
        let app=try fixture();defer {try? FileManager.default.removeItem(at:app.deletingLastPathComponent())}
        let session=try AssessmentReviewSession.capture(app)
        let archive=try InspectionArchive.decode(session.archiveBytes)
        let item=try XCTUnwrap(archive.attachments.first)
        guard case .assessments(let document)=try AIRSOpenedReport.attachment(archive,id:item.id) else {return XCTFail("Explicit assessment route")}
        let imported=AssessmentReviewSession(document:document,archiveBytes:session.archiveBytes,sourceURLs:[app.deletingLastPathComponent().appendingPathComponent("saved.airsreview")])
        XCTAssertNil(imported.evaluationID);XCTAssertNil(imported.identity)
        let owner=AIRSFileOpen(hasModal:{false});owner.assessmentReview=imported
        XCTAssertNil(owner.runAssessment(.signatureValidity,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace()))
        XCTAssertEqual(imported.archiveBytes,session.archiveBytes)
    }
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-assessments-20261020/workspace-tests/\(UUID())/Owned.app")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at:project.appendingPathComponent("fixtures/generated/before.macho"),to:root.appendingPathComponent("Contents/MacOS/Main"))
        try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"Main","CFBundleIdentifier":"owned.assessment"],format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
        return root
    }
}
private struct MetadataOnlyChecker:AssessmentChecking {
    func check(_ kind:AssessmentKind,at url:URL) async throws -> AssessmentCheckResult {
        guard kind == .signingInformation else {throw InspectionArchiveError.invalid}
        return .init(.passed,"Owned metadata only")
    }
}
