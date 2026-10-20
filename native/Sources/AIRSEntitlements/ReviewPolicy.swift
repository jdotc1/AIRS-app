import Foundation
import AIRSCore
import EntitlementDiffCore

public enum PolicyStatus:String,Codable,Sendable {case passed,failed,incomplete}
public enum PolicyEvaluationMode:String,Codable,Sendable {case liveArtifact,historicalRecord}
public struct PolicyEvaluationContext:Sendable {
    public let id:UUID
    public let expectedContentIdentities:[String:String]
    public let mode:PolicyEvaluationMode
    public let reviewDigest:String
    public let reviewOrigin:AssessmentAvailability
    public init(id:UUID,expectedContentIdentities:[String:String],mode:PolicyEvaluationMode,reviewDigest:String,
                reviewOrigin:AssessmentAvailability = .importedHistory) {
        self.id=id;self.expectedContentIdentities=expectedContentIdentities;self.mode=mode
        self.reviewDigest=reviewDigest;self.reviewOrigin=reviewOrigin
    }
}
public struct PolicyResult:Codable,Sendable {
    public let evaluationID:UUID
    public let mode:PolicyEvaluationMode
    public let policyDigest:String
    public let status:PolicyStatus
    public let violations:[String]
    public let missingEvidence:[String]
    public init(evaluationID:UUID,mode:PolicyEvaluationMode,policyDigest:String,status:PolicyStatus,violations:[String],missingEvidence:[String]) {
        self.evaluationID=evaluationID;self.mode=mode;self.policyDigest=policyDigest;self.status=status
        self.violations=violations;self.missingEvidence=missingEvidence
    }
    public var exitStatus:Int32 {status == .incomplete ? 2 : status == .failed ? 1 : 0}
    public func data() throws -> Data {var bytes=try ReviewPolicy.encoder.encode(self);bytes.append(10);return bytes}
}
public struct PolicyRule:Codable,Sendable {
    public enum Check:String,Codable,Sendable {case requiredArchitectures,acknowledgedEntitlementChanges,signatureValidity,symbolMatches}
    public let check:Check
    public let componentRelativePath:String
    public let architecture:String?
    public let scopeDescription:String?
    public init(check:Check,componentRelativePath:String,architecture:String?,scopeDescription:String?=nil) {
        self.check=check;self.componentRelativePath=componentRelativePath;self.architecture=architecture;self.scopeDescription=scopeDescription
    }
}
/// Canonical typed EntitlementValue JSON bytes preserve Boolean/Integer, UTF-8
/// strings and absent(nil) distinctions without a competing value decoder.
public struct PolicyAcknowledgement:Codable,Sendable {
    public let reviewDigest:String
    public let reportDigest:String
    public let componentRelativePath:String
    public let architecture:String
    public let keyUTF8:Data
    public let beforeValue:Data?
    public let afterValue:Data?
    public init(reviewDigest:String,reportDigest:String,componentRelativePath:String,architecture:String,keyUTF8:Data,beforeValue:Data?,afterValue:Data?) {
        self.reviewDigest=reviewDigest;self.reportDigest=reportDigest;self.componentRelativePath=componentRelativePath
        self.architecture=architecture;self.keyUTF8=keyUTF8;self.beforeValue=beforeValue;self.afterValue=afterValue
    }
}
public struct ReviewPolicy:Codable,Sendable {
    public static let kind="airs.review-policy"
    /// Interpretation of the schema-1 review, not an invented extractor version.
    public static let currentReviewModel="airs.component.review.schema1.policy1"
    public let kind:String
    public let schemaVersion:Int
    public let reviewModel:String
    public let rules:[PolicyRule]
    public let acknowledgements:[PolicyAcknowledgement]
    public init(reviewModel:String=Self.currentReviewModel,rules:[PolicyRule],acknowledgements:[PolicyAcknowledgement]=[]) throws {
        kind=Self.kind;schemaVersion=1;self.reviewModel=reviewModel;self.rules=rules;self.acknowledgements=acknowledgements;try validate()
    }
    static var encoder:JSONEncoder {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return e}
    public func data() throws -> Data {try validate();return try Self.encoder.encode(self)}
    public static func decode(_ bytes:Data) throws -> Self {
        guard bytes.count <= 2_097_152 else {throw InspectionArchiveError.limit}
        try EvidenceEnvelopeJSON.validate(bytes)
        let root=try PolicyJSON.object(bytes,keys:["kind","schemaVersion","reviewModel","rules","acknowledgements"])
        for (key,allowed) in [("rules",Set(["check","componentRelativePath","architecture","scopeDescription"])),("acknowledgements",Set(["reviewDigest","reportDigest","componentRelativePath","architecture","keyUTF8","beforeValue","afterValue"]))] {
            guard let rows=root[key] as? [[String:Any]],rows.count <= 256,rows.allSatisfy({Set($0.keys).isSubset(of:allowed)}) else {throw InspectionArchiveError.invalid}
        }
        let p=try JSONDecoder().decode(Self.self,from:bytes);try p.validate();return p
    }
    func validate() throws {
        guard kind == Self.kind,schemaVersion == 1,!rules.isEmpty,rules.count <= 128,acknowledgements.count <= 256,
              !reviewModel.isEmpty,reviewModel.utf8.count <= 256 else {throw InspectionArchiveError.invalid}
        var unique=Set<Data>()
        for rule in rules {
            guard Self.validPath(rule.componentRelativePath),unique.insert(try Self.encoder.encode(rule)).inserted else {throw InspectionArchiveError.invalid}
            if rule.check == .signatureValidity {
                guard rule.componentRelativePath == "@app-root",rule.architecture == nil,let scope=rule.scopeDescription,!scope.isEmpty,scope.utf8.count <= 4096 else {throw InspectionArchiveError.invalid}
            } else {
                guard rule.scopeDescription == nil,let a=rule.architecture,Architecture(rawValue:a) != nil else {throw InspectionArchiveError.invalid}
            }
        }
        for a in acknowledgements {
            guard Self.validDigest(a.reviewDigest),Self.validDigest(a.reportDigest),Self.validPath(a.componentRelativePath),
                  Architecture(rawValue:a.architecture) != nil,!a.keyUTF8.isEmpty,a.keyUTF8.count <= 4096,
                  String(data:a.keyUTF8,encoding:.utf8) != nil,(a.beforeValue?.count ?? 0) <= 65_536,(a.afterValue?.count ?? 0) <= 65_536,
                  a.beforeValue != nil || a.afterValue != nil else {throw InspectionArchiveError.invalid}
        }
    }
    static func validPath(_ path:String)->Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        return !parts.isEmpty && path.utf8.count <= 4096 && parts.allSatisfy{!$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")}
    }
    static func validDigest(_ value:String)->Bool {value.utf8.count == 64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    public static func scopeKey(componentRelativePath:String,architecture:String?,scopeDescription:String)->String {
        // UTF-8/base64 avoids String canonical-equivalence or delimiter joins.
        let fields=[Data(componentRelativePath.utf8).base64EncodedString(),architecture ?? "whole-app",Data(scopeDescription.utf8).base64EncodedString()]
        return fields.joined(separator:":")
    }
    private static func normalized(_ review:ComponentReview) throws -> ComponentReview {
        try ComponentComparison.review(previous:review.previous,current:review.current,architecture:review.architecture,
            entitlementResults:review.entitlementResults,previousDeclarations:review.previousDeclarations,currentDeclarations:review.currentDeclarations)
    }
    private static func canonicalReport(_ report:EntitlementDiffCore.ComparisonReport) throws -> Data {
        // Saved provenance is session state. Normalize it once so live -> archive
        // round trips do not change acknowledgement identities through notices.
        let saved=try SavedReport.parse(report.jsonData())
        return try EntitlementDiffCore.ComparisonReport(previous:saved.previous,current:saved.current).jsonData()
    }
    public static func reviewDigest(_ review:ComponentReview) throws -> String {
        let r=try ComponentComparison.review(previous:review.previous,current:review.current,architecture:review.architecture,
            entitlementResults:review.entitlementResults,previousDeclarations:review.previousDeclarations,currentDeclarations:review.currentDeclarations)
        var parts=[try ComponentInventoryDocumentCodec.encode(r.previous),try ComponentInventoryDocumentCodec.encode(r.current),Data(r.architecture.rawValue.utf8),try encoder.encode(r.previousDeclarations),try encoder.encode(r.currentDeclarations)]
        for outcome in r.entitlementResults {
            switch outcome {
            case .compared(let id,_,let report):parts += [Data(id.uuidString.utf8),try Self.canonicalReport(report)]
            case .unavailable(let id,_,let reason):parts += [Data(id.uuidString.utf8),Data(reason.utf8)]
            }
        }
        return AssessmentDocument.digest(try encoder.encode(parts))
    }
    /// Explicit authoring helper: callers choose whether to accept these exact
    /// changes. The evaluator never invokes it or edits observed reports.
    public static func acknowledgements(for supplied:ComponentReview) throws -> [PolicyAcknowledgement] {
        let review=try normalized(supplied)
        let digest=try reviewDigest(review)
        var rows:[PolicyAcknowledgement]=[]
        for outcome in review.entitlementResults {
            guard case .compared(let id,let arch,let report)=outcome,
                  let match=review.matching.matches.first(where:{$0.id == id}),
                  let path=review.current.components.first(where:{$0.id == match.currentID})?.relativePath else {continue}
            for change in report.changes {
                rows.append(.init(reviewDigest:digest,reportDigest:AssessmentDocument.digest(try Self.canonicalReport(report)),componentRelativePath:path,architecture:arch.rawValue,keyUTF8:Data(change.key.utf8),
                    beforeValue:try change.previous.map{try encoder.encode($0)},afterValue:try change.current.map{try encoder.encode($0)}))
            }
        }
        return rows
    }
    public func evaluate(_ supplied:ComponentReview,assessments:[AvailableAssessment],context:PolicyEvaluationContext)->PolicyResult {
        var violations:[String]=[],missing:[String]=[]
        let policyDigest=(try? data()).map(AssessmentDocument.digest) ?? "invalid"
        do {
            try validate()
            let review=try Self.normalized(supplied)
            let digest=try Self.reviewDigest(review)
            if digest != context.reviewDigest {missing.append("Expected review identity does not match these observations.")}
            if reviewModel != Self.currentReviewModel {missing.append("Review interpretation model changed or is unknown; explicit policy review is required.")}
            if context.mode == .liveArtifact && context.reviewOrigin != .currentRun(context.id) {missing.append("Live-artifact mode requires a review from this evaluation; imported records are historical.")}
            for rule in rules {
                let label=rule.check.rawValue+" · "+rule.componentRelativePath+" · "+(rule.architecture ?? "whole-app")
                let records=review.current.components.filter{$0.relativePath.utf8.elementsEqual(rule.componentRelativePath.utf8)}
                let record=records.first
                if rule.check != .signatureValidity {
                    guard records.count == 1,let record else {missing.append(label+": component not observed uniquely.");continue}
                    guard rule.architecture == review.architecture.rawValue,record.architectures.contains(review.architecture.rawValue),record.readIssues.isEmpty else {missing.append(label+": requested architecture was unavailable or differs from review scope.");continue}
                }
                switch rule.check {
                case .requiredArchitectures:
                    guard review.current.scope.completion == .completeWithinScope,review.current.scope.issues.isEmpty,review.current.scope.exclusions.isEmpty else {missing.append(label+": inventory scope is incomplete.");continue}
                case .acknowledgedEntitlementChanges:
                    guard let record,let match=review.matching.matches.first(where:{$0.currentID == record.id && $0.relation == .sameLocation}),
                          let outcome=review.entitlementResults.first(where:{$0.matchID == match.id}),case .compared(_,_,let report)=outcome else {missing.append(label+": no performed exact-location entitlement comparison.");continue}
                    if report.previous.presence != report.current.presence {violations.append(label+": entitlement representation changed; schema-1 acknowledgments do not waive this observation.")}
                    let reportDigest=AssessmentDocument.digest(try Self.canonicalReport(report))
                    for change in report.changes {
                        let before=try change.previous.map{try Self.encoder.encode($0)},after=try change.current.map{try Self.encoder.encode($0)}
                        let accepted=acknowledgements.contains {$0.reviewDigest == digest && $0.reportDigest == reportDigest && $0.componentRelativePath.utf8.elementsEqual(rule.componentRelativePath.utf8) && $0.architecture == rule.architecture && $0.keyUTF8 == Data(change.key.utf8) && $0.beforeValue == before && $0.afterValue == after}
                        if !accepted {violations.append(label+": unacknowledged UTF-8 key "+Data(change.key.utf8).base64EncodedString())}
                    }
                case .signatureValidity:
                    let key=Self.scopeKey(componentRelativePath:rule.componentRelativePath,architecture:nil,scopeDescription:rule.scopeDescription ?? "")
                    guard let expected=context.expectedContentIdentities[key],let doc=context.expectedContentIdentities[key+":document"],
                          expected.hasPrefix("sha256:"),Self.validDigest(String(expected.dropFirst(7))),doc.hasPrefix("sha256:"),Self.validDigest(String(doc.dropFirst(7))) else {missing.append(label+": expected scoped content/document identities are missing.");continue}
                    let candidates=assessments.filter {a in let e=a.evidence
                        return e.kind == .signatureValidity && e.componentRelativePath.utf8.elementsEqual(rule.componentRelativePath.utf8) && e.architecture == nil && e.scopeDescription.utf8.elementsEqual((rule.scopeDescription ?? "").utf8) && e.subjectFileDigest.map{"sha256:"+$0} == expected && "sha256:"+e.subjectDocumentDigest == doc && (context.mode == .historicalRecord || a.origin == .currentRun(context.id))
                    }
                    guard candidates.count == 1,let evidence=candidates.first?.evidence else {missing.append(label+": no unique performed assessment with matching origin and content/scope identity.");continue}
                    switch evidence.outcome {
                    case .passed:break
                    case .failed:violations.append(label+": recorded signature validity failed.")
                    case .unavailable,.cancelled,.notPerformed:missing.append(label+": signature validity was not completed.")
                    }
                case .symbolMatches:missing.append(label+": no qualified symbol/source-match evidence exists in this review format.")
                }
            }
        } catch {missing.append("Invalid policy or review evidence: "+error.localizedDescription)}
        return .init(evaluationID:context.id,mode:context.mode,policyDigest:policyDigest,status:missing.isEmpty ? (violations.isEmpty ? .passed:.failed):.incomplete,violations:violations,missingEvidence:missing)
    }
}
enum PolicyJSON {
    static func object(_ data:Data,keys:Set<String>) throws -> [String:Any] {
        try EvidenceEnvelopeJSON.validate(data)
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],Set(root.keys).isSubset(of:keys) else {throw InspectionArchiveError.invalid};return root
    }
}
