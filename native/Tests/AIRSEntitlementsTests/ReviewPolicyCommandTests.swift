import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class ReviewPolicyCommandTests:XCTestCase {
    func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-policy-command-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    func fixture(_ root:URL) throws -> [URL] {
        let scope=InventoryScope(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[])
        let path="Contents/MacOS/Owned"
        func inventory()->ComponentInventory {.init(scope:scope,components:[.init(relativePath:path,kind:"app",declaredBundleID:"dev.airs.owned.policy",architectures:["arm64"])])}
        let a=inventory(),b=inventory(),match=try ComponentMatcher.match(previous:a,current:b).matches[0]
        func snapshot(_ id:UUID,_ value:Bool)->EntitlementSnapshot {.init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"dev.airs.owned.policy",architecture:.arm64,presence:.dictionaryPresent,origin:.syntheticExample,entitlements:.init(["expected-change":.boolean(value),"unacknowledged-change":.boolean(value)]))}
        let report=try EntitlementDiffCore.ComparisonReport(previous:snapshot(a.components[0].id,false),current:snapshot(b.components[0].id,true))
        let review=try ComponentComparison.review(previous:a,current:b,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:report)])
        try ComponentReviewArchive.encode(review).write(to:root.appendingPathComponent("owned.airsreview"))
        let ack=try ReviewPolicy.acknowledgements(for:review)
        let changes=PolicyRule(check:.acknowledgedEntitlementChanges,componentRelativePath:path,architecture:"arm64")
        let architecture=PolicyRule(check:.requiredArchitectures,componentRelativePath:path,architecture:"arm64")
        let policies=[try ReviewPolicy(rules:[architecture,changes],acknowledgements:ack),try ReviewPolicy(rules:[architecture,changes],acknowledgements:Array(ack.prefix(1))),try ReviewPolicy(rules:[changes,.init(check:.requiredArchitectures,componentRelativePath:path,architecture:"x86_64"),.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")],acknowledgements:Array(ack.prefix(1)))]
        var urls:[URL]=[]
        let evaluation=UUID()
        for (index,policy) in policies.enumerated() {
            let name=["passed","failed","incomplete"][index]
            try policy.data().write(to:root.appendingPathComponent(name+"-policy.json"))
            let object:[String:Any]=["kind":"airs.review-policy-request","schemaVersion":1,"evaluationID":evaluation.uuidString,"mode":"historicalRecord","reviewArchive":"owned.airsreview","policy":name+"-policy.json","expectedReviewDigest":try ReviewPolicy.reviewDigest(review),"expectedContentIdentities":[String:String](),"assessments":[String]()]
            let url=root.appendingPathComponent(name+"-request.json")
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]).write(to:url);urls.append(url)
        }
        return urls
    }
    func testCommandExitCodesAndStableEvaluatorParity() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        for (index,url) in try fixture(root).enumerated() {
            let command=try ReviewPolicyCommand(arguments:["--request",url.path]),prepared=try command.prepare(),result=try await command.run()
            XCTAssertEqual(result.exitStatus,Int32(index));XCTAssertEqual(result.standardOutput,try prepared.evaluate().data())
            if index == 2 {XCTAssertEqual(result.policyResult.violations.count,1);XCTAssertEqual(result.policyResult.missingEvidence.count,2)}
        }
    }
    func testExclusiveOutputAndInputAliasesCannotOverwrite() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root)[0],output=root.appendingPathComponent("result.json")
        let command=try ReviewPolicyCommand(arguments:["--request",request.path,"--output",output.path])
        let result=try await command.run();XCTAssertEqual(try Data(contentsOf:output),result.standardOutput)
        do {_=try await command.run();XCTFail("Existing output")} catch {}
        let before=try Data(contentsOf:request),alias=root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:request)
        do {_=try await ReviewPolicyCommand(arguments:["--request",request.path,"--output",alias.path]).run();XCTFail("Input alias")} catch {}
        XCTAssertEqual(try Data(contentsOf:request),before)
    }
    func testStrictRequestPolicyAndExplicitMode() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root)[0],original=try Data(contentsOf:request)
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        value["schemaVersion"]=true
        try JSONSerialization.data(withJSONObject:value).write(to:request)
        XCTAssertThrowsError(try ReviewPolicyCommand(arguments:["--request",request.path]).prepare())
        value["schemaVersion"]=1;value.removeValue(forKey:"mode")
        try JSONSerialization.data(withJSONObject:value).write(to:request)
        XCTAssertThrowsError(try ReviewPolicyCommand(arguments:["--request",request.path]).prepare())
        XCTAssertThrowsError(try ReviewPolicy(rules:[]))
        let bad=Data("{\"kind\":\"airs.review-policy\",\"schemaVersion\":1,\"reviewModel\":\"x\",\"rules\":[{\"check\":\"future\",\"componentRelativePath\":\"Main\",\"architecture\":\"arm64\"}],\"acknowledgements\":[]}".utf8)
        XCTAssertThrowsError(try ReviewPolicy.decode(bad))
    }
    func testLiveRequestNeverPromotesImportedReview() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let request=try fixture(root)[0]
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:request)) as? [String:Any]);object["mode"]="liveArtifact"
        try JSONSerialization.data(withJSONObject:object).write(to:request)
        let result=try await ReviewPolicyCommand(arguments:["--request",request.path]).run()
        XCTAssertEqual(result.exitStatus,2);XCTAssertTrue(result.policyResult.missingEvidence.contains{$0.contains("imported records")})
    }
    func testWriteOwnedCIExample() throws {
        // A new fixture authoring operation, not a repeat verification of exports.
        guard let path=ProcessInfo.processInfo.environment["AIRS_POLICY_EXAMPLE_ROOT"] else {return}
        let root=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        _=try fixture(root)
    }
}
