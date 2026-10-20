import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class ReviewPolicyTests:XCTestCase {
    let path="Contents/MacOS/Main"
    func review(changes:Bool=true) throws -> ComponentReview {
        let scope=InventoryScope(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[])
        let a=ComponentInventory(scope:scope,components:[.init(relativePath:path,kind:"app",architectures:["arm64"])])
        let b=ComponentInventory(scope:scope,components:[.init(relativePath:path,kind:"app",architectures:["arm64"])])
        let match=try ComponentMatcher.match(previous:a,current:b).matches[0]
        func snap(_ id:UUID,_ value:Bool)->EntitlementSnapshot {.init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"owned",architecture:.arm64,presence:.dictionaryPresent,entitlements:.init(["owned":.boolean(value)]))}
        let report=try EntitlementDiffCore.ComparisonReport(previous:snap(a.components[0].id,false),current:snap(b.components[0].id,changes))
        return try ComponentComparison.review(previous:a,current:b,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:report)])
    }
    func context(_ r:ComponentReview,mode:PolicyEvaluationMode = .historicalRecord,id:UUID=UUID(),identities:[String:String]=[:]) throws -> PolicyEvaluationContext {
        .init(id:id,expectedContentIdentities:identities,mode:mode,reviewDigest:try ReviewPolicy.reviewDigest(r))
    }
    func testMissingEvidenceNeverPasses() throws {
        let r=try review();let p=try ReviewPolicy(rules:[.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")])
        XCTAssertEqual(p.evaluate(r,assessments:[],context:try context(r)).status,.incomplete)
        let empty=try ComponentComparison.review(previous:r.previous,current:r.current,architecture:.arm64,entitlementResults:[])
        let changes=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:path,architecture:"arm64")])
        XCTAssertEqual(changes.evaluate(empty,assessments:[],context:try context(empty)).status,.incomplete)
    }
    func testKnownViolationPlusMissingEvidenceIsIncomplete() throws {
        let r=try review();let p=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:path,architecture:"arm64"),.init(check:.symbolMatches,componentRelativePath:path,architecture:"arm64")])
        let result=p.evaluate(r,assessments:[],context:try context(r))
        XCTAssertEqual(result.status,.incomplete);XCTAssertFalse(result.violations.isEmpty);XCTAssertFalse(result.missingEvidence.isEmpty)
    }
    func testArchitectureScopeMismatchIncomplete() throws {
        let r=try review();let p=try ReviewPolicy(rules:[.init(check:.requiredArchitectures,componentRelativePath:path,architecture:"x86_64")])
        XCTAssertEqual(p.evaluate(r,assessments:[],context:try context(r)).status,.incomplete)
    }
    func testModelChangeRequiresReview() throws {
        let r=try review(changes:false);let p=try ReviewPolicy(reviewModel:"future.model",rules:[.init(check:.requiredArchitectures,componentRelativePath:path,architecture:"arm64")])
        XCTAssertEqual(p.evaluate(r,assessments:[],context:try context(r)).status,.incomplete)
    }
    func assessment(_ r:ComponentReview,file:String=String(repeating:"a",count:64)) -> AssessmentEvidence {
        .init(kind:.signatureValidity,subjectDocumentDigest:String(repeating:"b",count:64),subjectFileDigest:file,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app",startedAt:Date(),completedAt:Date(),hostOS:"test",toolOrAPI:"test",argumentsOrFlags:[],outcome:.passed,diagnostic:"")
    }
    func testAssessmentForDifferentArtifactIsIncomplete() throws {
        let r=try review();let p=try ReviewPolicy(rules:[.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")])
        let key=ReviewPolicy.scopeKey(componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")
        let c=try context(r,identities:[key:"sha256:"+String(repeating:"c",count:64),key+":document":"sha256:"+String(repeating:"b",count:64)])
        XCTAssertEqual(p.evaluate(r,assessments:[.imported(assessment(r))],context:c).status,.incomplete)
    }
    func testHistoricalAssessmentCannotSatisfyFreshRequirement() throws {
        let r=try review();let p=try ReviewPolicy(rules:[.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")])
        let key=ReviewPolicy.scopeKey(componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")
        let c=try context(r,mode:.liveArtifact,identities:[key:"sha256:"+String(repeating:"a",count:64),key+":document":"sha256:"+String(repeating:"b",count:64)])
        let result=p.evaluate(r,assessments:[.imported(assessment(r))],context:c)
        XCTAssertEqual(result.status,.incomplete)
    }
    func testAcknowledgementDoesNotEraseObservation() throws {
        let r=try review();let a=try ReviewPolicy.acknowledgements(for:r)
        let p=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:path,architecture:"arm64")],acknowledgements:a)
        XCTAssertEqual(p.evaluate(r,assessments:[],context:try context(r)).status,.passed)
        guard case .compared(_,_,let report)=r.entitlementResults[0] else{return XCTFail()}
        XCTAssertEqual(report.changes.count,1)
        let other=try review();XCTAssertEqual(p.evaluate(other,assessments:[],context:try context(other)).status,.failed)
    }
}

final class PolicyBoundaryTests:XCTestCase {
    func testForgedPublicMatchingCannotBorrowAnotherComponentsReport() throws {
        let scope=InventoryScope(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[])
        func inventory()->ComponentInventory {.init(scope:scope,components:[.init(relativePath:"Contents/MacOS/A",kind:"app",architectures:["arm64"]),.init(relativePath:"Contents/MacOS/B",kind:"app",architectures:["arm64"])])}
        let a=inventory(),b=inventory(),matches=try ComponentMatcher.match(previous:a,current:b)
        let first=matches.matches[0]
        func snap(_ id:UUID)->EntitlementSnapshot {.init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"owned",architecture:.arm64,presence:.dictionaryPresent,entitlements:.init())}
        let report=try EntitlementDiffCore.ComparisonReport(previous:snap(a.components[0].id),current:snap(b.components[0].id))
        let valid=try ComponentComparison.review(previous:a,current:b,architecture:.arm64,entitlementResults:[.compared(matchID:first.id,architecture:.arm64,report:report)])
        let forged=ComponentReview(previous:a,current:b,matching:.init(matches:[.init(id:first.id,previousID:first.previousID,currentID:b.components[1].id,relation:.sameLocation,reasons:[])],previousScope:scope,currentScope:scope),architecture:.arm64,entitlementResults:valid.entitlementResults,previousDeclarations:[],currentDeclarations:[])
        let policy=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:"Contents/MacOS/B",architecture:"arm64")])
        let result=policy.evaluate(forged,assessments:[],context:.init(id:UUID(),expectedContentIdentities:[:],mode:.historicalRecord,reviewDigest:try ReviewPolicy.reviewDigest(valid)))
        XCTAssertEqual(result.status,.incomplete)
    }
    func testCanonicalDigestSurvivesArchiveReopen() throws {
        let r=try ReviewPolicyTests().review(),digest=try ReviewPolicy.reviewDigest(r)
        let reopened=try ComponentReviewArchive.decode(InspectionArchive.decode(ComponentReviewArchive.encode(r)))
        XCTAssertEqual(try ReviewPolicy.reviewDigest(reopened),digest)
        let policy=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:"Contents/MacOS/Main",architecture:"arm64")],acknowledgements:ReviewPolicy.acknowledgements(for:r))
        XCTAssertEqual(policy.evaluate(reopened,assessments:[],context:.init(id:UUID(),expectedContentIdentities:[:],mode:.historicalRecord,reviewDigest:digest)).status,.passed)
    }
}

final class PolicyEvidenceBoundaryTests:XCTestCase {
    func testFreshAssessmentRequiresBothDigestsScopeAndEvaluation() throws {
        let helper=ReviewPolicyTests(),r=try helper.review(changes:false),id=UUID()
        let evidence=helper.assessment(r),key=ReviewPolicy.scopeKey(componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")
        let identities=[key:"sha256:"+String(repeating:"a",count:64),key+":document":"sha256:"+String(repeating:"b",count:64)]
        let c=PolicyEvaluationContext(id:id,expectedContentIdentities:identities,mode:.liveArtifact,reviewDigest:try ReviewPolicy.reviewDigest(r),reviewOrigin:.currentRun(id))
        let policy=try ReviewPolicy(rules:[.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"whole app")])
        XCTAssertEqual(policy.evaluate(r,assessments:[.init(evidence:evidence,origin:.currentRun(id))],context:c).status,.passed)
        XCTAssertEqual(policy.evaluate(r,assessments:[.init(evidence:evidence,origin:.currentRun(UUID()))],context:c).status,.incomplete)
        var wrong=identities;wrong[key+":document"]="sha256:"+String(repeating:"d",count:64)
        let mismatch=PolicyEvaluationContext(id:id,expectedContentIdentities:wrong,mode:.liveArtifact,reviewDigest:c.reviewDigest,reviewOrigin:.currentRun(id))
        XCTAssertEqual(policy.evaluate(r,assessments:[.init(evidence:evidence,origin:.currentRun(id))],context:mismatch).status,.incomplete)
        let otherScope=try ReviewPolicy(rules:[.init(check:.signatureValidity,componentRelativePath:"@app-root",architecture:nil,scopeDescription:"other scope")])
        XCTAssertEqual(otherScope.evaluate(r,assessments:[.init(evidence:evidence,origin:.currentRun(id))],context:c).status,.incomplete)
    }
    func testAcknowledgementRequiresExactTypedValuesAndUTF8Key() throws {
        let r=try ReviewPolicyTests().review(),a=try XCTUnwrap(ReviewPolicy.acknowledgements(for:r).first)
        let badType=PolicyAcknowledgement(reviewDigest:a.reviewDigest,reportDigest:a.reportDigest,componentRelativePath:a.componentRelativePath,architecture:a.architecture,keyUTF8:a.keyUTF8,beforeValue:Data("{\"type\":\"integer\",\"value\":\"0\"}".utf8),afterValue:a.afterValue)
        let badKey=PolicyAcknowledgement(reviewDigest:a.reviewDigest,reportDigest:a.reportDigest,componentRelativePath:a.componentRelativePath,architecture:a.architecture,keyUTF8:Data("other".utf8),beforeValue:a.beforeValue,afterValue:a.afterValue)
        let context=PolicyEvaluationContext(id:UUID(),expectedContentIdentities:[:],mode:.historicalRecord,reviewDigest:try ReviewPolicy.reviewDigest(r))
        for bad in [badType,badKey] {
            let policy=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:a.componentRelativePath,architecture:"arm64")],acknowledgements:[bad])
            XCTAssertEqual(policy.evaluate(r,assessments:[],context:context).status,.failed)
        }
    }
    func testRepresentationOnlyChangeCannotDisappearOrBeWaived() throws {
        let initial=try ReviewPolicyTests().review(changes:false),a=initial.previous.components[0],b=initial.current.components[0],match=initial.matching.matches[0]
        func snap(_ record:ComponentRecord,_ presence:EntitlementPresence)->EntitlementSnapshot {.init(sourceName:ComponentComparison.sourceName(componentID:record.id),signingIdentifier:"owned",architecture:.arm64,presence:presence,entitlements:.init())}
        let report=try EntitlementDiffCore.ComparisonReport(previous:snap(a,.notPresent),current:snap(b,.dictionaryPresent))
        let r=try ComponentComparison.review(previous:initial.previous,current:initial.current,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:report)])
        XCTAssertTrue(report.changes.isEmpty)
        let policy=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:a.relativePath,architecture:"arm64")])
        XCTAssertEqual(policy.evaluate(r,assessments:[],context:.init(id:UUID(),expectedContentIdentities:[:],mode:.historicalRecord,reviewDigest:try ReviewPolicy.reviewDigest(r))).status,.failed)
    }
}

final class PolicyUTF8Tests:XCTestCase {
    func testCanonicallyEquivalentKeysRemainDifferentAcknowledgements() throws {
        let initial=try ReviewPolicyTests().review(),a=initial.previous.components[0],b=initial.current.components[0],match=initial.matching.matches[0]
        func snapshot(_ id:UUID,_ value:Bool)throws->EntitlementSnapshot {
            .init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"owned",architecture:.arm64,presence:.dictionaryPresent,entitlements:try .init(entries:[.init(key:"é",value:.boolean(value)),.init(key:"e\u{301}",value:.boolean(value))]))
        }
        let report=try EntitlementDiffCore.ComparisonReport(previous:snapshot(a.id,false),current:snapshot(b.id,true))
        let r=try ComponentComparison.review(previous:initial.previous,current:initial.current,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:report)])
        let ack=try ReviewPolicy.acknowledgements(for:r)
        XCTAssertEqual(ack.count,2);XCTAssertNotEqual(ack[0].keyUTF8,ack[1].keyUTF8)
        let policy=try ReviewPolicy(rules:[.init(check:.acknowledgedEntitlementChanges,componentRelativePath:a.relativePath,architecture:"arm64")],acknowledgements:[ack[0]])
        let result=policy.evaluate(r,assessments:[],context:.init(id:UUID(),expectedContentIdentities:[:],mode:.historicalRecord,reviewDigest:try ReviewPolicy.reviewDigest(r)))
        XCTAssertEqual(result.status,.failed);XCTAssertEqual(result.violations.count,1)
    }
}
