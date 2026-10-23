import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class PolicyAcknowledgementCommandTests:XCTestCase {
    func folder() throws -> URL {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-policy-acknowledgement-authoring-20261021-tests", isDirectory: true).path).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    func fixture(_ root:URL,acknowledged:Bool=false,check:PolicyRule.Check = .acknowledgedEntitlementChanges,model:String=ReviewPolicy.currentReviewModel) throws -> URL {
        let scope=InventoryScope(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[])
        let path="Contents/MacOS/Owned"
        func inventory()->ComponentInventory {.init(scope:scope,components:[.init(relativePath:path,kind:"app",architectures:["arm64"])])}
        let before=inventory(),after=inventory(),match=try ComponentMatcher.match(previous:before,current:after).matches[0]
        func snapshot(_ id:UUID,_ value:Bool)->EntitlementSnapshot {
            .init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"dev.airs.owned.policy-proposal",architecture:.arm64,presence:.dictionaryPresent,origin:.syntheticExample,entitlements:.init(["first":.boolean(value),"second":.boolean(value)]))
        }
        let comparison=try ComparisonReport(previous:snapshot(before.components[0].id,false),current:snapshot(after.components[0].id,true))
        let review=try ComponentComparison.review(previous:before,current:after,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:comparison)])
        try ComponentReviewArchive.encode(review).write(to:root.appendingPathComponent("review.airsreview"))
        let acks=acknowledged ? Array(try ReviewPolicy.acknowledgements(for:review).prefix(1)) : []
        let policy=try ReviewPolicy(reviewModel:model,rules:[.init(check:check,componentRelativePath:path,architecture:"arm64")],acknowledgements:acks)
        try policy.data().write(to:root.appendingPathComponent("policy.json"))
        let wire:[String:Any]=["kind":"airs.review-policy-request","schemaVersion":1,"evaluationID":UUID().uuidString,"mode":"historicalRecord","reviewArchive":"review.airsreview","policy":"policy.json","expectedReviewDigest":try ReviewPolicy.reviewDigest(review),"expectedContentIdentities":[String:String](),"assessments":[String]()]
        let url=root.appendingPathComponent("request.json");try JSONSerialization.data(withJSONObject:wire).write(to:url);return url
    }
    func testProducesExactReviewableCandidatesWithoutChangingPolicy() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root),policyURL=root.appendingPathComponent("policy.json"),original=try Data(contentsOf:policyURL)
        let bytes=try await PolicyAcknowledgementCommand(arguments:["--request",request.path]).run()
        let proposal=try JSONDecoder().decode(PolicyAcknowledgementProposal.self,from:bytes)
        XCTAssertEqual(proposal.kind,"airs.policy-acknowledgement-proposal");XCTAssertEqual(proposal.candidates.count,2)
        XCTAssertEqual(proposal.evidenceOrigin,"importedHistory")
        XCTAssertEqual(Set(proposal.candidates.map{String(decoding:$0.keyUTF8,as:UTF8.self)}),["first","second"])
        XCTAssertTrue(proposal.candidates.allSatisfy{$0.componentRelativePath == "Contents/MacOS/Owned" && $0.architecture == "arm64" && $0.beforeValue != $0.afterValue})
        XCTAssertEqual(try Data(contentsOf:policyURL),original)
        XCTAssertThrowsError(try ReviewPolicy.decode(bytes))
    }
    func testExistingExactAcknowledgmentIsNotProposedAgain() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root,acknowledged:true)
        let prepared=try ReviewPolicyCommand(arguments:["--request",request.path]).prepare()
        let proposal=try PolicyAcknowledgementCommand.propose(prepared)
        XCTAssertEqual(proposal.candidates.count,1)
        XCTAssertNotEqual(proposal.candidates.first?.keyUTF8,prepared.policy.acknowledgements.first?.keyUTF8)
        XCTAssertEqual(proposal.reviewDigest,prepared.context.reviewDigest)
    }
    func testRulesWithoutEntitlementChangesProduceEmptyProposalNotPass() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root,check:.requiredArchitectures)
        let bytes=try await PolicyAcknowledgementCommand(arguments:["--request",request.path]).run()
        let wire=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual((wire["candidates"] as? [Any])?.count,0);XCTAssertNil(wire["status"])
    }
    func testUnknownModelOrWrongReviewIdentityCannotPropose() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        var request=try fixture(root,model:"future-review-model")
        var prepared=try ReviewPolicyCommand(arguments:["--request",request.path]).prepare()
        XCTAssertThrowsError(try PolicyAcknowledgementCommand.propose(prepared))
        request=try fixture(root)
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:request)) as? [String:Any]);wire["expectedReviewDigest"]=String(repeating:"0",count:64)
        try JSONSerialization.data(withJSONObject:wire).write(to:request)
        prepared=try ReviewPolicyCommand(arguments:["--request",request.path]).prepare()
        XCTAssertThrowsError(try PolicyAcknowledgementCommand.propose(prepared))
    }
    func testOutputCannotOverwriteExistingFileOrAnyInputAlias() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root),output=root.appendingPathComponent("proposal.json")
        let command=try PolicyAcknowledgementCommand(arguments:["--request",request.path,"--output",output.path])
        let bytes=try await command.run();XCTAssertEqual(try Data(contentsOf:output),bytes)
        do {_=try await command.run();XCTFail("Existing output accepted")}catch{}
        let alias=root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root.appendingPathComponent("policy.json"))
        do {_=try await PolicyAcknowledgementCommand(arguments:["--request",request.path,"--output",alias.path]).run();XCTFail("Input alias accepted")}catch{}
    }
    func testCancelledPreparationPublishesNothing() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root),output=root.appendingPathComponent("cancelled.json")
        let command=try PolicyAcknowledgementCommand(arguments:["--request",request.path,"--output",output.path])
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try await command.run()
        }
        do {_=try await task.value;XCTFail("Cancelled command returned output")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    }
}
