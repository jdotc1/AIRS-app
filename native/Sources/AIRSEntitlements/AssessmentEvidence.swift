import Foundation
import CryptoKit
import AIRSCore
import EntitlementDiffCore

public enum AssessmentOutcome: String, Codable, Sendable { case passed, failed, unavailable, cancelled, notPerformed }
public enum AssessmentKind: String, Codable, CaseIterable, Sendable { case signingInformation, signatureValidity, localDistribution }
public struct AssessmentEvidence: Codable, Sendable {
    public let kind: AssessmentKind
    public let subjectDocumentDigest: String
    public let subjectFileDigest: String?
    public let componentRelativePath: String
    public let architecture: String?
    public let scopeDescription: String
    public let startedAt: Date
    public let completedAt: Date
    public let hostOS: String
    public let toolOrAPI: String
    public let argumentsOrFlags: [String]
    public let outcome: AssessmentOutcome
    public let diagnostic: String
    public init(kind:AssessmentKind,subjectDocumentDigest:String,subjectFileDigest:String?,componentRelativePath:String,architecture:String?,scopeDescription:String,startedAt:Date,completedAt:Date,hostOS:String,toolOrAPI:String,argumentsOrFlags:[String],outcome:AssessmentOutcome,diagnostic:String) {
        self.kind=kind; self.subjectDocumentDigest=subjectDocumentDigest; self.subjectFileDigest=subjectFileDigest
        self.componentRelativePath=componentRelativePath; self.architecture=architecture; self.scopeDescription=scopeDescription
        self.startedAt=startedAt; self.completedAt=completedAt; self.hostOS=hostOS; self.toolOrAPI=toolOrAPI
        self.argumentsOrFlags=argumentsOrFlags; self.outcome=outcome; self.diagnostic=diagnostic
    }
}
public enum AssessmentAvailability: Equatable, Sendable { case currentRun(UUID), importedHistory }
public struct AvailableAssessment: Sendable {
    public let evidence: AssessmentEvidence
    public let origin: AssessmentAvailability
    public init(evidence:AssessmentEvidence,origin:AssessmentAvailability) { self.evidence=evidence; self.origin=origin }
    public static func imported(_ evidence:AssessmentEvidence) -> Self { .init(evidence:evidence,origin:.importedHistory) }
}
public struct AssessmentDocument: Codable, Sendable {
    public static let kind = "airs.assessments"
    public let kind: String
    public let schemaVersion: Int
    public let subjectDocument: Data
    public let results: [AssessmentEvidence]
    public static func digest(_ bytes:Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    public init(subjectDocument:Data,results:[AssessmentEvidence]) throws {
        self.kind=Self.kind; schemaVersion=1; self.subjectDocument=subjectDocument; self.results=results
        try validate()
    }
    public func outcome(for kind:AssessmentKind) -> AssessmentOutcome { results.last { $0.kind == kind }?.outcome ?? .notPerformed }
    private func validate() throws {
        guard kind == Self.kind, schemaVersion == 1, subjectDocument.count <= 524_288, results.count <= 64 else { throw InspectionArchiveError.limit }
        let digest = Self.digest(subjectDocument)
        for value in results {
            let parts=value.componentRelativePath.split(separator:"/",omittingEmptySubsequences:false)
            guard value.subjectDocumentDigest == digest,
                  value.subjectFileDigest.map({ $0.count == 64 && $0.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) }) ?? true,
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  value.componentRelativePath.utf8.count <= 4096, value.diagnostic.utf8.count <= 65_536,
                  value.scopeDescription.utf8.count <= 4096, value.toolOrAPI.utf8.count <= 1024,
                  value.hostOS.utf8.count <= 1024, value.architecture.map({$0.utf8.count <= 128}) ?? true,
                  value.argumentsOrFlags.count <= 32, value.argumentsOrFlags.allSatisfy({$0.utf8.count <= 4096}),
                  value.startedAt.timeIntervalSince1970.isFinite, value.completedAt.timeIntervalSince1970.isFinite,
                  value.completedAt >= value.startedAt else { throw InspectionArchiveError.invalid }
        }
    }
    public func data() throws -> Data { try validate(); let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return try e.encode(self) }
    public static func decode(_ data:Data) throws -> Self {
        guard data.count <= 4_194_304 else { throw InspectionArchiveError.limit }
        try EvidenceEnvelopeJSON.validate(data)
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(root.keys) == ["kind","schemaVersion","subjectDocument","results"],
              let rows=root["results"] as? [[String:Any]], rows.count <= 64,
              rows.allSatisfy({Set($0.keys).isSubset(of:["kind","subjectDocumentDigest","subjectFileDigest","componentRelativePath","architecture","scopeDescription","startedAt","completedAt","hostOS","toolOrAPI","argumentsOrFlags","outcome","diagnostic"])}) else { throw InspectionArchiveError.invalid }
        let value=try JSONDecoder().decode(Self.self,from:data); try value.validate(); return value
    }
    public func archive() throws -> Data {
        let bytes=try data()
        return try InspectionArchive(attachments:[.init(id:UUID(),kind:Self.kind,schemaVersion:1,mediaType:"application/json",sha256:Self.digest(bytes),byteCount:bytes.count,bytes:bytes)]).encode()
    }
}
