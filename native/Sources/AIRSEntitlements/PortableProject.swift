import Foundation
import AIRSCore

public struct PortableProjectEvidence: Codable, Sendable {
    public let id: UUID
    public let path: String
    public let sha256: String
    public let bytes: Int
}
struct PortableProjectMetadata: Codable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int
}
public struct PortableProjectInventory: Codable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    public let projectID: UUID
    let metadata: PortableProjectMetadata
    public let evidence: [PortableProjectEvidence]
    public let originalBinariesIncluded: Bool
    public var disclosure: String {
        "Exports project metadata and \(evidence.count) original evidence archives. Notes and evidence may contain sensitive strings or source paths; bytes are preserved. Original apps, dSYMs and batch checkpoints are excluded."
    }
    static func path(_ id: UUID) -> String { "evidence/"+id.uuidString.lowercased()+".airsreview" }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 2_097_152 else { throw InspectionArchiveError.limit }
        let root = try BoundJSON.object(BoundJSON.parse(bytes),keys:["kind","schemaVersion","projectID","metadata","evidence","originalBinariesIncluded"])
        guard try BoundJSON.text(root["kind"]) == "airs.project-package",try BoundJSON.integer(root["schemaVersion"]) == 1,
              root["originalBinariesIncluded"] == .boolean(false),case .array(let entries) = root["evidence"],entries.count <= 128 else { throw InspectionArchiveError.invalid }
        _ = try BoundJSON.uuid(root["projectID"])
        let metadata = try BoundJSON.object(root["metadata"] ?? .null,keys:["path","sha256","bytes"])
        guard try BoundJSON.text(metadata["path"]) == "project.json",try BoundJSON.integer(metadata["bytes"],positive:true) <= 2_097_152 else { throw InspectionArchiveError.invalid }
        _ = try BoundJSON.digest(metadata["sha256"])
        var ids = Set<UUID>(), paths = Set<String>()
        for entry in entries {
            let item = try BoundJSON.object(entry,keys:["id","path","sha256","bytes"])
            let id = try BoundJSON.uuid(item["id"]), path = try BoundJSON.text(item["path"])
            guard path == Self.path(id),ids.insert(id).inserted,paths.insert(path.lowercased()).inserted,
                  try BoundJSON.integer(item["bytes"],positive:true) <= InspectionArchive.maximumBytes else { throw InspectionArchiveError.invalid }
            _ = try BoundJSON.digest(item["sha256"])
        }
        return try JSONDecoder().decode(Self.self,from:bytes)
    }
}

enum PortableProjectFiles {
    static let maximumBytes = 256 * 1_048_576
    static func physicalDirectory(_ url: URL) throws {
        guard url.isFileURL,url.standardizedFileURL.path.utf8.elementsEqual(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8) else { throw InspectionArchiveError.invalid }
        let info = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard info.isDirectory == true,info.isSymbolicLink != true else { throw InspectionArchiveError.invalid }
    }
    static func freshStage(for target: URL) throws -> URL {
        guard target.isFileURL,!FileManager.default.fileExists(atPath:target.path),
              target.standardizedFileURL.path == target.path else { throw BoundReviewError.invalid("Choose a new physical directory; existing destinations are preserved.") }
        try physicalDirectory(target.deletingLastPathComponent())
        // fileExists does not see a dangling link; resource lookup does.
        if (try? target.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw InspectionArchiveError.invalid }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".airsproject-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        return stage
    }
    static func files(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath:directory.path))
    }
}
