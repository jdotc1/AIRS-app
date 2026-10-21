import Foundation

/// Reuses the existing native CLI host; no app/image is inspected or executed.
public enum PortableProjectCommand {
    public static let usage = """
    airs-entitlements project preview --store STORE --project UUID
    airs-entitlements project export --store STORE --project UUID --output NEW.airsproject --confirm-original-evidence
    airs-entitlements project inventory --package PACKAGE.airsproject
    airs-entitlements project reconstruct --package PACKAGE.airsproject --output NEW_STORE

    Preview identifies metadata, notes and evidence included by export. Evidence
    bytes remain verbatim and may contain sensitive strings/paths. Original apps,
    dSYMs and batch checkpoints are excluded. Reconstruction requires a new
    physical store directory; it never merges into or overwrites an existing store.
    """
    public static func run(arguments: [String]) async throws -> Data {
        guard let operation=arguments.first else { throw BoundReviewError.invalid(usage) }
        var values:[String:String]=[:],confirmed=false,index=1
        while index < arguments.count {
            let key=arguments[index]
            if key == "--confirm-original-evidence" {
                guard !confirmed else {throw BoundReviewError.invalid(usage)}
                confirmed=true;index += 1;continue
            }
            guard ["--store","--project","--output","--package"].contains(key),values[key] == nil,index+1 < arguments.count else {throw BoundReviewError.invalid(usage)}
            values[key]=arguments[index+1];index += 2
        }
        func path(_ key:String) throws -> URL {
            guard let value=values[key],value.hasPrefix("/") else {throw BoundReviewError.invalid("Use explicit absolute local paths.\n"+usage)}
            return URL(fileURLWithPath:value)
        }
        func projectID() throws -> UUID {
            guard let text=values["--project"],let id=UUID(uuidString:text) else {throw BoundReviewError.invalid(usage)};return id
        }
        func output(_ object:Any) throws -> Data {
            var bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted]);bytes.append(10);return bytes
        }
        switch operation {
        case "preview":
            guard Set(values.keys) == ["--store","--project"],!confirmed else {throw BoundReviewError.invalid(usage)}
            let store=InspectionProjectStore(root:try path("--store")),project=try await store.metadata(projectID())
            return try output(["projectID":project.id.uuidString,"name":project.name,"revision":project.revision,
                "evidence":project.evidence.map{["id":$0.id.uuidString,"sha256":$0.digest,"kinds":$0.kinds] as [String:Any]},
                "annotationCount":project.annotations.count,"historicalBatchLinks":project.batchLinks.count,"originalBinariesIncluded":false,
                "disclosure":"All project notes and referenced evidence are included verbatim and may contain sensitive strings or source paths. No app, dSYM, bookmark or batch checkpoint is included."])
        case "export":
            guard Set(values.keys) == ["--store","--project","--output"],confirmed else {throw BoundReviewError.invalid("Preview the project, then explicitly confirm original evidence inclusion.\n"+usage)}
            let store=InspectionProjectStore(root:try path("--store")),id=try projectID(),target=try path("--output")
            try await store.exportPortableProject(id,to:target)
            return try output(["written":target.path,"projectID":id.uuidString,"originalBinariesIncluded":false])
        case "inventory":
            guard Set(values.keys) == ["--package"],!confirmed else {throw BoundReviewError.invalid(usage)}
            let value=try PortableProjectReader.inventory(at:path("--package"))
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted];return try encoder.encode(value)
        case "reconstruct":
            guard Set(values.keys) == ["--package","--output"],!confirmed else {throw BoundReviewError.invalid(usage)}
            let target=try path("--output")
            let store=try await PortableProjectReader.reconstruct(at:path("--package"),to:target)
            let entries=try await store.entries()
            return try output(["store":target.path,"projectIDs":entries.compactMap{$0.project?.id.uuidString},"historicalBatchLinksOnly":true])
        default:throw BoundReviewError.invalid(usage)
        }
    }
}
