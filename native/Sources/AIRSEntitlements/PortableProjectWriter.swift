import Foundation
import AIRSCore

public enum PortableProjectWriter {
    /// Only store-admitted bytes enter this writer; existing evidence digests are
    /// reused while collecting the snapshot. Metadata retains its original bytes.
    static func write(project: InspectionProject, metadata: Data, evidence: [UUID:Data], to target: URL,
                      beforePreflight: (URL) throws -> Void = {_ in}) throws {
        try project.validate(); try Task.checkCancellation()
        guard !metadata.isEmpty,metadata.count <= 2_097_152 else {throw InspectionArchiveError.limit}
        var records: [PortableProjectEvidence] = [], total = metadata.count
        for reference in project.evidence {
            guard let bytes = evidence[reference.id],!bytes.isEmpty,bytes.count <= InspectionArchive.maximumBytes,
                  bytes.count <= PortableProjectFiles.maximumBytes-total else { throw InspectionArchiveError.limit }
            total += bytes.count
            records.append(.init(id:reference.id,path:PortableProjectInventory.path(reference.id),sha256:reference.digest,bytes:bytes.count))
        }
        guard evidence.count == records.count else { throw InspectionArchiveError.invalid }
        let manifest = PortableProjectInventory(kind:"airs.project-package",schemaVersion:1,projectID:project.id,
            metadata:.init(path:"project.json",sha256:AssessmentDocument.digest(metadata),bytes:metadata.count),
            evidence:records,originalBinariesIncluded:false)
        let encoder = JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
        let encoded = try encoder.encode(manifest)
        guard encoded.count <= 2_097_152,encoded.count <= PortableProjectFiles.maximumBytes-total else { throw InspectionArchiveError.limit }
        let stage = try PortableProjectFiles.freshStage(for:target)
        defer {try? FileManager.default.removeItem(at:stage)}
        try FileManager.default.createDirectory(at:stage.appendingPathComponent("evidence"),withIntermediateDirectories:false)
        try metadata.write(to:stage.appendingPathComponent("project.json"),options:.withoutOverwriting)
        for record in records {
            try Task.checkCancellation()
            guard let bytes = evidence[record.id] else { throw InspectionArchiveError.invalid }
            try bytes.write(to:stage.appendingPathComponent(record.path),options:.withoutOverwriting)
        }
        try encoded.write(to:stage.appendingPathComponent("manifest.json"),options:.withoutOverwriting)
        try beforePreflight(stage)
        try Task.checkCancellation()
        // First admission of newly written artifact bytes, not a recheck of
        // unchanged source exports. Reuse the ordinary native package decoder.
        let admitted = try PortableProjectReader.prepare(at:stage)
        guard admitted.projectBytes == metadata else {throw InspectionArchiveError.invalid}
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:stage,to:target)
    }
}
