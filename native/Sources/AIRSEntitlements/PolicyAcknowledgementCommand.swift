import Foundation
import AIRSCore
import EntitlementDiffCore

/// A reviewable authoring proposal, never an accepted policy or evaluation result.
public struct PolicyAcknowledgementProposal:Codable,Sendable {
    public let kind:String
    public let schemaVersion:Int
    public let evaluationID:UUID
    public let reviewDigest:String
    public let policyDigest:String
    public let requestedMode:PolicyEvaluationMode
    public let evidenceOrigin:String
    public let candidates:[PolicyAcknowledgement]
    public let limitations:[String]
    public func data() throws -> Data {
        var bytes=try ReviewPolicy.encoder.encode(self)
        guard bytes.count < 2_097_152 else {throw InspectionArchiveError.limit}
        bytes.append(10);return bytes
    }
}

public struct PolicyAcknowledgementCommand:Sendable {
    public static let usage="""
    Usage: airs-entitlements propose-acknowledgements --request <request.json> [--output <new-proposal.json>]
    Prepare exact entitlement-change acknowledgment candidates from saved evidence.
    Only changes covered by the policy's entitlement-change rules are proposed;
    already acknowledged changes are excluded. Review each candidate explicitly.
    This creates a separate proposal, not a policy, acceptance or passing result.
    No policy or input is modified. No app, signature or symbol read occurs.
    Output is JSON on stdout; --output exclusively creates a new file.
    Exit: 0 proposal prepared (not policy passed); 2 input/output/capacity failure.
    """
    private let request:ReviewPolicyCommand
    public init(arguments:[String],directory:URL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)) throws {
        request=try ReviewPolicyCommand(arguments:arguments,directory:directory)
    }
    public static func propose(_ prepared:PreparedPolicyReview) throws -> PolicyAcknowledgementProposal {
        guard prepared.policy.reviewModel == ReviewPolicy.currentReviewModel,
              try ReviewPolicy.reviewDigest(prepared.review) == prepared.context.reviewDigest else {
            throw ReportError.invalidContents("Acknowledgment proposals require the known review model and the exact expected review identity.")
        }
        let rules=prepared.policy.rules.filter{$0.check == .acknowledgedEntitlementChanges}
        let existing=Set(try prepared.policy.acknowledgements.map{try ReviewPolicy.encoder.encode($0)})
        let candidates=try ReviewPolicy.acknowledgements(for:prepared.review).filter { value in
            guard rules.contains(where:{ $0.componentRelativePath.utf8.elementsEqual(value.componentRelativePath.utf8) && $0.architecture == value.architecture }) else {return false}
            return !existing.contains(try ReviewPolicy.encoder.encode(value))
        }
        guard candidates.count <= 256 else {throw InspectionArchiveError.limit}
        return .init(kind:"airs.policy-acknowledgement-proposal",schemaVersion:1,
            evaluationID:prepared.context.id,reviewDigest:prepared.context.reviewDigest,
            policyDigest:AssessmentDocument.digest(try prepared.policy.data()),requestedMode:prepared.context.mode,
            evidenceOrigin:"importedHistory",candidates:candidates,
            limitations:["Candidates require explicit review; no change is accepted by preparing this proposal.",
                         "This proposal is not a policy or a policy evaluation result. Zero candidates does not mean passed.",
                         "Bindings concern saved review/report identities and exact typed values, not a fresh app observation.",
                         "Entitlement representation changes, missing evidence, signature and symbol requirements are not waived."])
    }
    public func run() async throws -> Data {
        try Task.checkCancellation()
        let prepared=try request.prepare(),bytes=try Self.propose(prepared).data()
        try Task.checkCancellation()
        if let output=request.outputURL {
            try ReportDestination.validate(output,excluding:prepared.inputURLs)
            try bytes.write(to:output,options:.withoutOverwriting)
        }
        return bytes
    }
}
