import Foundation
import Darwin

/// Read-only metadata inventory, not admission of retained evidence or history.
public struct InspectionProjectCatalog:Codable,Sendable {
    public struct Row:Codable,Sendable {
        public let projectID:UUID
        public let name:String?
        public let revision:Int?
        public let evidenceReferenceCount:Int?
        public let annotationCount:Int?
        public let historicalBatchLinkCount:Int?
        public let issue:String?
    }
    public let format:String
    public let schemaVersion:Int
    public let store:String
    public let projectCount:Int
    public let readableCount:Int
    public let unreadableCount:Int
    public let evidenceValidated:Bool
    public let historicalOutcomesResolved:Bool
    public let queueRestored:Bool
    public let atomicSnapshot:Bool
    public let projects:[Row]

    public static func read(from root:URL) async throws -> Self {
        try Task.checkCancellation()
        guard root.isFileURL else {throw BoundReviewError.invalid("Use an absolute local project store.")}
        let physical=root.standardizedFileURL
        let values=try physical.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard physical.isFileURL,values.isDirectory == true,values.isSymbolicLink != true,
              physical.path.utf8.elementsEqual(physical.resolvingSymlinksInPath().path.utf8) else {
            throw BoundReviewError.invalid("Catalog requires an existing physical project store without symbolic-link ancestors.")
        }
        // Bound immediate directory work as well as the reader's UUID-row count.
        // Never descend into evidence, project subdirectories or symbolic links.
        var ids:[UUID]=[]
        let projectsRoot=physical.appendingPathComponent("Projects")
        var projectsInfo=stat()
        let projectsStatus=projectsRoot.path.withCString {Darwin.lstat($0,&projectsInfo)}
        if projectsStatus != 0,errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        if projectsStatus == 0 {
            let directory=try projectsRoot.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard directory.isDirectory == true,directory.isSymbolicLink != true else {
                throw BoundReviewError.invalid("Invalid catalog Projects directory.")
            }
            var enumerationError:Error?
            guard let children=FileManager.default.enumerator(at:projectsRoot,includingPropertiesForKeys:nil,
                options:[.skipsSubdirectoryDescendants],errorHandler:{_,error in enumerationError=error;return false}) else {
                throw BoundReviewError.invalid("Cannot enumerate catalog Projects directory.")
            }
            var count=0
            while let child=children.nextObject() as? URL {
                try Task.checkCancellation();count += 1
                guard count <= 128 else {throw BoundReviewError.invalid("Catalog directory entry limit exceeded.")}
                if let id=UUID(uuidString:child.lastPathComponent) {
                    ids.append(id)
                    guard ids.count <= 64 else {throw BoundReviewError.invalid("Catalog project limit exceeded.")}
                }
            }
            if let enumerationError {throw enumerationError}
        }
        // Reuse the same bounded, no-follow metadata reader used by entries().
        // Read the admitted UUID set directly to avoid a second unbounded listing.
        let store=InspectionProjectStore(root:physical)
        var rows:[Row]=[]
        rows.reserveCapacity(ids.count)
        // Adapt MacScope's immutable snapshot-list materialization/cancellation
        // pattern; the catalog admits at most 64 manifests of at most 2 MiB each.
        for id in ids.sorted(by:{$0.uuidString < $1.uuidString}) {
            try Task.checkCancellation()
            do {
                let p=try await store.metadata(id)
                rows.append(.init(projectID:id,name:p.name,revision:p.revision,
                    evidenceReferenceCount:p.evidence.count,annotationCount:p.annotations.count,
                    historicalBatchLinkCount:p.batchLinks.count,issue:nil))
            } catch {
                try Task.checkCancellation()
                rows.append(.init(projectID:id,name:nil,revision:nil,evidenceReferenceCount:nil,
                    annotationCount:nil,historicalBatchLinkCount:nil,issue:error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        let readable=rows.filter{$0.issue == nil}.count
        return .init(format:"airs.project-catalog",schemaVersion:1,store:physical.path,
            projectCount:rows.count,readableCount:readable,unreadableCount:rows.count-readable,
            evidenceValidated:false,historicalOutcomesResolved:false,queueRestored:false,
            atomicSnapshot:false,projects:rows)
    }
}
