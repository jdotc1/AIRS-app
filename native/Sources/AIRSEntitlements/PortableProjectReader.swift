import Foundation
import AIRSCore

/// A locally admitted immutable snapshot plus cheap currentness witnesses.
/// Never serialized as a trust flag; preview and confirmation share this value.
public struct PortableProjectAdmission: Sendable {
    public let inventory: PortableProjectInventory
    public let project: InspectionProject
    public let packageURL: URL
    let manifestBytes: Data
    let projectBytes: Data
    fileprivate let evidence: [UUID:Data]
    fileprivate let stamps: [URL:ResumeFileIdentity]
}

public enum PortableProjectReader {
    private static func admit(_ package: URL, maximumBytes: Int) throws -> PortableProjectAdmission {
        guard maximumBytes > 0,maximumBytes <= PortableProjectFiles.maximumBytes else { throw InspectionArchiveError.limit }
        try Task.checkCancellation();try PortableProjectFiles.physicalDirectory(package)
        guard try PortableProjectFiles.files(package) == ["manifest.json","project.json","evidence"] else { throw InspectionArchiveError.invalid }
        let evidenceRoot=package.appendingPathComponent("evidence")
        try PortableProjectFiles.physicalDirectory(evidenceRoot)
        let (manifestBytes,initialManifest)=try BoundReviewFiles.snapshot(package.appendingPathComponent("manifest.json"),limit:min(2_097_152,maximumBytes))
        let inventory=try PortableProjectInventory.decode(manifestBytes)
        guard try PortableProjectFiles.files(evidenceRoot) == Set(inventory.evidence.map{URL(fileURLWithPath:$0.path).lastPathComponent}) else { throw InspectionArchiveError.invalid }
        var stamps: [URL:ResumeFileIdentity] = [:]
        // Also bind the manifest after its descriptor snapshot, avoiding reparsing it.
        let manifestURL=package.appendingPathComponent("manifest.json")
        let (projectBytes,projectStamp)=try BoundReviewFiles.snapshot(package.appendingPathComponent("project.json"),limit:2_097_152)
        guard projectBytes.count == inventory.metadata.bytes,AssessmentDocument.digest(projectBytes) == inventory.metadata.sha256 else { throw InspectionArchiveError.invalid }
        let project=try InspectionProject.decode(projectBytes)
        guard project.id == inventory.projectID,project.evidence.map(\.id) == inventory.evidence.map(\.id) else { throw InspectionArchiveError.invalid }
        var total=manifestBytes.count+projectBytes.count, evidence:[UUID:Data]=[:]
        guard total <= maximumBytes else { throw InspectionArchiveError.limit }
        stamps[package.appendingPathComponent("project.json")]=projectStamp
        for (entry,reference) in zip(inventory.evidence,project.evidence) {
            try Task.checkCancellation()
            guard entry.sha256 == reference.digest,entry.bytes <= maximumBytes-total else { throw InspectionArchiveError.limit }
            let url=package.appendingPathComponent(entry.path)
            let (bytes,stamp)=try BoundReviewFiles.snapshot(url,limit:entry.bytes)
            guard bytes.count == entry.bytes,AssessmentDocument.digest(bytes) == entry.sha256 else { throw InspectionArchiveError.invalid }
            _=try InspectionArchive.decode(bytes)
            stamps[url]=stamp;evidence[entry.id]=bytes;total += bytes.count
        }
        stamps[manifestURL]=initialManifest
        let admission=PortableProjectAdmission(inventory:inventory,project:project,packageURL:package,manifestBytes:manifestBytes,projectBytes:projectBytes,evidence:evidence,stamps:stamps)
        try validateCurrent(admission)
        return admission
    }
    static func validateCurrent(_ admission: PortableProjectAdmission) throws {
        let package=admission.packageURL,evidenceRoot=package.appendingPathComponent("evidence")
        try PortableProjectFiles.physicalDirectory(package);try PortableProjectFiles.physicalDirectory(evidenceRoot)
        for (url,stamp) in admission.stamps {
            guard try ResumeFileIdentity.capture(url) == stamp else { throw BoundReviewError.invalid("Package changed after preview. Open it again before reconstructing.") }
        }
        guard try PortableProjectFiles.files(package) == ["manifest.json","project.json","evidence"],
              try PortableProjectFiles.files(evidenceRoot) == Set(admission.inventory.evidence.map{URL(fileURLWithPath:$0.path).lastPathComponent}) else {throw InspectionArchiveError.invalid}
    }
    public static func prepare(at package: URL, maximumBytes: Int = 256 * 1_048_576) throws -> PortableProjectAdmission {
        try admit(package,maximumBytes:maximumBytes)
    }
    public static func inventory(at package: URL, maximumBytes: Int = 256 * 1_048_576) throws -> PortableProjectInventory {
        try admit(package,maximumBytes:maximumBytes).inventory
    }
    public static func reconstruct(at package: URL, to target: URL,
        beforePublish: @Sendable () throws -> Void = {}) async throws -> InspectionProjectStore {
        try await reconstruct(prepare(at:package),to:target,beforePublish:beforePublish)
    }
    public static func reconstruct(_ admitted: PortableProjectAdmission, to target: URL,
        beforePublish: @Sendable () throws -> Void = {}) async throws -> InspectionProjectStore {
        guard !target.standardizedFileURL.path.hasPrefix(admitted.packageURL.standardizedFileURL.path+"/") else { throw InspectionArchiveError.invalid }
        try Task.checkCancellation();try validateCurrent(admitted)
        let stage=try PortableProjectFiles.freshStage(for:target)
        defer {try? FileManager.default.removeItem(at:stage)}
        let store=InspectionProjectStore(root:stage)
        try await store.restorePortable(admitted.project,metadata:admitted.projectBytes,evidence:admitted.evidence)
        try Task.checkCancellation();try beforePublish();try Task.checkCancellation();try validateCurrent(admitted)
        try FileManager.default.moveItem(at:stage,to:target)
        return InspectionProjectStore(root:target)
    }
}

// Copy only admitted bytes, never an unchecked directory tree. This preserves the
// schema-1 child exactly when explicitly wrapping it with historical outcomes.
extension PortableProjectReader {
    static func writeAdmitted(_ admission: PortableProjectAdmission, to target: URL) throws {
        try validateCurrent(admission)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("evidence"), withIntermediateDirectories: false)
        try admission.manifestBytes.write(to: target.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try admission.projectBytes.write(to: target.appendingPathComponent("project.json"), options: .withoutOverwriting)
        for entry in admission.inventory.evidence {
            try Task.checkCancellation()
            guard let bytes = admission.evidence[entry.id] else { throw InspectionArchiveError.invalid }
            try bytes.write(to: target.appendingPathComponent(entry.path), options: .withoutOverwriting)
        }
        try validateCurrent(admission)
    }
}
