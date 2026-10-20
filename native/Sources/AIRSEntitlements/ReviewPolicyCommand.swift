import Foundation
import AIRSCore
import EntitlementDiffCore

public struct PreparedPolicyReview:Sendable {
    public let policy:ReviewPolicy
    public let review:ComponentReview
    public let assessments:[AvailableAssessment]
    public let context:PolicyEvaluationContext
    public let inputURLs:[URL]
    public func evaluate()->PolicyResult {policy.evaluate(review,assessments:assessments,context:context)}
}
/// File-only policy review. This command never reads a target app or performs OS
/// assessment. Every imported assessment and the review have historical origin.
public struct ReviewPolicyCommand:Sendable {
    public static let usage="""
    Usage: airs-entitlements review --request <request.json> [--output <new-result.json>]
    Read a schema-1 airs.review-policy-request and its named saved reports/policy.
    Request mode must explicitly be historicalRecord or liveArtifact. No new app,
    signature or symbol reads occur. Imported records cannot satisfy fresh checks.
    Relative paths resolve from the request folder. Output is stable JSON on stdout;
    --output also exclusively creates a new file. Existing destinations are refused.
    Exit: 0 policy passed; 1 policy failed; 2 incomplete or input/output failure.
    A passed historical record is not a current-artifact or safety/trust verdict.
    """
    public let requestURL:URL
    public let outputURL:URL?
    public init(arguments:[String],directory:URL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)) throws {
        var values:[String:String]=[:],index=0
        while index < arguments.count {
            let key=arguments[index]
            guard ["--request","--output"].contains(key),values[key] == nil,index+1 < arguments.count,
                  !arguments[index+1].isEmpty,!arguments[index+1].hasPrefix("--"),!arguments[index+1].contains("\0") else {throw ReviewPolicyCommandError.arguments}
            values[key]=arguments[index+1];index += 2
        }
        guard let request=values["--request"] else {throw ReviewPolicyCommandError.arguments}
        func resolve(_ path:String)->URL {URL(fileURLWithPath:path.hasPrefix("/") ? path:directory.path+"/"+path).standardizedFileURL}
        requestURL=resolve(request);outputURL=values["--output"].map(resolve)
    }
    public struct Result:Sendable {
        public let policyResult:PolicyResult
        public let standardOutput:Data
        public var exitStatus:Int32 {policyResult.exitStatus}
    }
    public func prepare() throws -> PreparedPolicyReview {
        let bytes=try ReportFiles.readBounded(requestURL,limit:524_288)
        let root=try PolicyJSON.object(bytes,keys:["kind","schemaVersion","evaluationID","mode","reviewArchive","policy","expectedReviewDigest","expectedContentIdentities","assessments"])
        guard root["kind"] as? String == "airs.review-policy-request",root["schemaVersion"] as? Int == 1 else {throw InspectionArchiveError.invalid}
        let request=try JSONDecoder().decode(Request.self,from:bytes)
        guard request.kind == "airs.review-policy-request",request.schemaVersion == 1 else {throw InspectionArchiveError.invalid}
        guard request.assessments.count <= 16,request.expectedContentIdentities.count <= 256,
              ReviewPolicy.validDigest(request.expectedReviewDigest),request.expectedContentIdentities.allSatisfy({$0.key.utf8.count <= 16_384 && $0.value.utf8.count <= 256}) else {throw InspectionArchiveError.limit}
        func url(_ path:String) throws -> URL {
            guard !path.isEmpty,path.utf8.count <= 4096,!path.contains("\0") else {throw InspectionArchiveError.invalid}
            return URL(fileURLWithPath:path.hasPrefix("/") ? path:requestURL.deletingLastPathComponent().path+"/"+path).standardizedFileURL
        }
        let archiveURL=try url(request.reviewArchive),policyURL=try url(request.policy),assessmentURLs=try request.assessments.map(url)
        let review=try ComponentReviewArchive.decode(InspectionArchive.decode(ReportFiles.readBounded(archiveURL,limit:InspectionArchive.maximumBytes)))
        let policy=try ReviewPolicy.decode(ReportFiles.readBounded(policyURL,limit:2_097_152))
        var assessments:[AvailableAssessment]=[]
        for item in assessmentURLs {
            let bytes=try ReportFiles.readBounded(item,limit:4_194_304)
            assessments += try AssessmentDocument.decode(bytes).results.map(AvailableAssessment.imported)
        }
        let context=PolicyEvaluationContext(id:request.evaluationID,expectedContentIdentities:request.expectedContentIdentities,mode:request.mode,reviewDigest:request.expectedReviewDigest)
        return .init(policy:policy,review:review,assessments:assessments,context:context,inputURLs:[requestURL,archiveURL,policyURL]+assessmentURLs)
    }
    public func run() async throws -> Result {
        try Task.checkCancellation()
        let prepared=try prepare(),result=prepared.evaluate(),bytes=try result.data()
        if let outputURL {
            try ReportDestination.validate(outputURL,excluding:prepared.inputURLs)
            try bytes.write(to:outputURL,options:.withoutOverwriting)
        }
        return .init(policyResult:result,standardOutput:bytes)
    }
    private struct Request:Decodable {
        let kind:String
        let schemaVersion:Int
        let evaluationID:UUID
        let mode:PolicyEvaluationMode
        let reviewArchive:String
        let policy:String
        let expectedReviewDigest:String
        let expectedContentIdentities:[String:String]
        let assessments:[String]
    }
}
public enum ReviewPolicyCommandError:Error,LocalizedError,Sendable {
    case arguments
    public var errorDescription:String? {"Invalid review arguments. Use review --help; --request is required."}
}
