import XCTest
import AIRSCore
import Darwin
@testable import AIRSEntitlements
final class AssessmentTests: XCTestCase {
    func testMetadataDoesNotPerformOtherChecksAndImportedPassStaysHistorical() throws {
        let evidence = AssessmentEvidence(kind:.signingInformation,subjectDocumentDigest:AssessmentDocument.digest(Data("owned".utf8)),subjectFileDigest:nil,componentRelativePath:"Contents/MacOS/Main",architecture:nil,scopeDescription:"metadata only",startedAt:Date(),completedAt:Date(),hostOS:"owned",toolOrAPI:"fake",argumentsOrFlags:[],outcome:.passed,diagnostic:"metadata")
        let document = try AssessmentDocument(subjectDocument:Data("owned".utf8),results:[evidence])
        XCTAssertEqual(document.outcome(for:.signatureValidity),.notPerformed)
        XCTAssertEqual(document.outcome(for:.localDistribution),.notPerformed)
        let archive = try InspectionArchive.decode(document.archive())
        let imported = try AssessmentDocument.decode(archive.attachments[0].bytes)
        XCTAssertEqual(imported.results[0].outcome,.passed)
        XCTAssertEqual(AvailableAssessment.imported(imported.results[0]).origin,.importedHistory)
    }
    func testContentIdentityRejectsChangesLinksAndBudgetWithoutRehash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-B3-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("owned")
        try Data("before".utf8).write(to:file)
        let identity = try AssessmentContentIdentity.capture(root)
        XCTAssertEqual(identity.digest.count,64)
        try identity.validate()
        try Data("changed".utf8).write(to:file)
        XCTAssertThrowsError(try identity.validate())
        XCTAssertThrowsError(try AssessmentContentIdentity.capture(root,maximumBytes:2))
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("link").path,withDestinationPath:"owned")
        XCTAssertThrowsError(try AssessmentContentIdentity.capture(root))
    }
    func testExtendedAttributesAreBoundAndMutationInvalidatesReceipt() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-assessments-20261020/xattrs/\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("resource");try Data("owned".utf8).write(to:file)
        func attribute(_ text:String) throws {
            let bytes=Data(text.utf8)
            let status=bytes.withUnsafeBytes {Darwin.setxattr(file.path,"dev.airs.owned",$0.baseAddress,bytes.count,0,0)}
            XCTAssertEqual(status,0)
        }
        try attribute("first")
        let before=try AssessmentContentIdentity.capture(root)
        try attribute("second")
        XCTAssertThrowsError(try before.validate())
        let after=try AssessmentContentIdentity.capture(root)
        XCTAssertNotEqual(before.digest,after.digest)
    }
    func testArchiveRejectsUnboundDocumentDigestAndUnknownOutcome() throws {
        let bytes=Data("owned".utf8),digest=AssessmentDocument.digest(bytes)
        let result=AssessmentEvidence(kind:.signatureValidity,subjectDocumentDigest:digest,subjectFileDigest:nil,componentRelativePath:"Contents",architecture:nil,scopeDescription:"owned",startedAt:Date(),completedAt:Date(),hostOS:"owned",toolOrAPI:"fake",argumentsOrFlags:[],outcome:.unavailable,diagnostic:"not performed by fake")
        let document=try AssessmentDocument(subjectDocument:bytes,results:[result])
        var root=try XCTUnwrap(JSONSerialization.jsonObject(with:document.data()) as? [String:Any])
        root["subjectDocument"]=Data("different".utf8).base64EncodedString()
        XCTAssertThrowsError(try AssessmentDocument.decode(JSONSerialization.data(withJSONObject:root)))
        root["subjectDocument"]=bytes.base64EncodedString()
        var rows=try XCTUnwrap(root["results"] as? [[String:Any]])
        rows[0]["outcome"]="trusted";root["results"]=rows
        XCTAssertThrowsError(try AssessmentDocument.decode(JSONSerialization.data(withJSONObject:root)))
    }

}
