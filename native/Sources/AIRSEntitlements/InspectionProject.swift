import Foundation
import AIRSCore
import EntitlementDiffCore

public struct ProjectEvidenceReference: Codable, Equatable, Identifiable, Sendable {
    public let id:UUID
    public let digest:String
    public let savedAt:Date
    public let extractionTimes:[Date]
    public let producerModels:[String]
    public let appVersions:[String]
    public let kinds:[String]
}
public struct ProjectAnnotation:Codable,Equatable,Identifiable,Sendable {
    public let id:UUID
    public let text:String
    public let acknowledged:Bool
    public let authoredAt:Date
    public let supersedes:UUID?
    public init(text:String,acknowledged:Bool,supersedes:UUID?=nil) {
        id=UUID();self.text=text;self.acknowledged=acknowledged;authoredAt=Date();self.supersedes=supersedes
    }
}
public struct ProjectBatchLink:Codable,Equatable,Identifiable,Sendable {
    public enum Family:String,Codable,Sendable {case audit,entitlements}
    public let id:UUID
    public let family:Family
    public let historyID:UUID
    public let rowIDs:[UUID]
    public let linkedAt:Date
    public init(family:Family,historyID:UUID,rowIDs:[UUID]) {
        id=UUID();self.family=family;self.historyID=historyID;self.rowIDs=rowIDs;linkedAt=Date()
    }
}
public struct ProjectHistoryEvent:Codable,Equatable,Identifiable,Sendable {
    public let id:UUID
    public let revision:Int
    public let date:Date
    public let action:String
}
/// Mutable review metadata. Original observations live only in immutable retained
/// archives; membership never implies that an original binary is retained.
public struct InspectionProject:Codable,Identifiable,Sendable {
    public let schemaVersion:Int
    public let id:UUID
    public var revision:Int
    public var name:String
    public let createdAt:Date
    public internal(set) var updatedAt:Date
    public internal(set) var evidence:[ProjectEvidenceReference]
    public internal(set) var pinnedBaselineID:UUID?
    public internal(set) var annotationIDs:[UUID]
    public internal(set) var annotations:[ProjectAnnotation]
    public internal(set) var batchLinks:[ProjectBatchLink]
    public internal(set) var history:[ProjectHistoryEvent]
    public init(name:String) {
        schemaVersion=1;id=UUID();revision=1;self.name=name;createdAt=Date();updatedAt=createdAt
        evidence=[];pinnedBaselineID=nil;annotationIDs=[];annotations=[];batchLinks=[];history=[]
    }
    public func validate() throws {
        guard schemaVersion == 1,revision > 0,revision <= 1_000_000,
              !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count <= 256,
              !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
              createdAt.timeIntervalSince1970.isFinite,updatedAt >= createdAt,
              evidence.count <= 128,Set(evidence.map(\.id)).count == evidence.count,
              pinnedBaselineID.map({id in evidence.contains{$0.id == id}}) ?? true,
              annotations.count <= 128,annotationIDs == annotations.map(\.id),Set(annotationIDs).count == annotationIDs.count,
              batchLinks.count <= 128,Set(batchLinks.map(\.id)).count == batchLinks.count,
              history.count <= 1024,Set(history.map(\.id)).count == history.count else {throw InspectionArchiveError.invalid}
        for item in evidence {
            guard item.digest.utf8.count == 64,item.digest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                  item.savedAt.timeIntervalSince1970.isFinite,item.extractionTimes.count <= 256,item.extractionTimes.allSatisfy({$0.timeIntervalSince1970.isFinite}),
                  item.producerModels.count <= 256,item.appVersions.count <= 256,item.kinds.count <= 256,
                  (item.producerModels+item.appVersions+item.kinds).allSatisfy({$0.utf8.count <= 4096}) else {throw InspectionArchiveError.invalid}
        }
        var seen=Set<UUID>()
        for note in annotations {
            guard note.text.utf8.count <= 8192,note.authoredAt.timeIntervalSince1970.isFinite,
                  note.supersedes.map(seen.contains) ?? true else {throw InspectionArchiveError.invalid}
            seen.insert(note.id)
        }
        for link in batchLinks {
            guard link.rowIDs.count <= 128,Set(link.rowIDs).count == link.rowIDs.count,link.linkedAt.timeIntervalSince1970.isFinite else {throw InspectionArchiveError.invalid}
        }
        var previous=0
        for event in history {
            guard event.revision > previous,event.revision <= revision,event.date.timeIntervalSince1970.isFinite,event.action.utf8.count <= 256 else {throw InspectionArchiveError.invalid}
            previous=event.revision
        }
    }
    public func data() throws -> Data {
        try validate();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let bytes=try encoder.encode(self);guard bytes.count <= 2_097_152 else {throw InspectionArchiveError.limit};return bytes
    }
    public static func decode(_ bytes:Data) throws -> Self {
        guard bytes.count <= 2_097_152 else {throw InspectionArchiveError.limit}
        try EvidenceEnvelopeJSON.validate(bytes)
        guard let root=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              Set(root.keys).isSubset(of:["schemaVersion","id","revision","name","createdAt","updatedAt","evidence","pinnedBaselineID","annotationIDs","annotations","batchLinks","history"]) else {throw InspectionArchiveError.invalid}
        let value=try JSONDecoder().decode(Self.self,from:bytes);try value.validate();return value
    }
}
public struct InspectionProjectEntry:Identifiable,Sendable {
    public let id:UUID
    public let project:InspectionProject?
    public let issue:String?
}
