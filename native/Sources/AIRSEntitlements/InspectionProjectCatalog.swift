import Foundation
import Darwin

/// Read-only metadata inventory, not admission of retained evidence or history.
public struct InspectionProjectCatalog:Codable,Sendable {
    public enum Ordering: String, Codable, Sendable {
        case name
    }
    public struct Row:Codable,Sendable {
        public let projectID:UUID
        public let name:String?
        public let revision:Int?
        public let evidenceReferenceCount:Int?
        public let annotationCount:Int?
        public let historicalBatchLinkCount:Int?
        public let issue:String?
    }
    public struct Selection: Codable, Sendable {
        public let nameContains: String
        public let examinedProjectCount: Int
        public let excludedReadableCount: Int
        public let unreadableRowsRetained: Bool
    }
    public let sort: Ordering?
    public let selection: Selection?
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

    public static func read(from root:URL, nameContains: String? = nil, sort: Ordering? = nil) async throws -> Self {
        try Task.checkCancellation()
        let locale = Locale(identifier: "en_US_POSIX")
        let foldedQuery: String?
        if let nameContains {
            guard !nameContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  nameContains.utf8.count <= 256,
                  !nameContains.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BoundReviewError.invalid("Name filter must contain 1–256 UTF-8 bytes, nonblank text and no control characters.")
            }
            foldedQuery = nameContains.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            guard foldedQuery?.isEmpty == false else {
                throw BoundReviewError.invalid("Name filter must contain searchable text.")
            }
        } else { foldedQuery = nil }
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
        // Search is display-name selection only. Never normalize project UUIDs,
        // filenames or evidence identity. Retain every unreadable row explicitly.
        let examinedCount = rows.count
        if let foldedQuery {
            rows = rows.filter { row in
                row.issue != nil || row.name?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                    .contains(foldedQuery) == true
            }
        }
        try Task.checkCancellation()
        if sort == .name {
            // Compare original UTF-8 bytes, without locale or filename normalization.
            // Unreadable rows have no trusted name and remain visible after names.
            rows.sort { lhs, rhs in
                switch (lhs.name, rhs.name) {
                case let (left?, right?):
                    if !left.utf8.elementsEqual(right.utf8) {
                        return left.utf8.lexicographicallyPrecedes(right.utf8)
                    }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
                return lhs.projectID.uuidString < rhs.projectID.uuidString
            }
        }
        try Task.checkCancellation()
        let readable=rows.filter{$0.issue == nil}.count
        let selection = nameContains.map {
            Selection(nameContains: $0, examinedProjectCount: examinedCount,
                      excludedReadableCount: examinedCount - rows.count, unreadableRowsRetained: true)
        }
        return .init(sort:sort,selection:selection,format:"airs.project-catalog",schemaVersion:1,store:physical.path,
            projectCount:rows.count,readableCount:readable,unreadableCount:rows.count-readable,
            evidenceValidated:false,historicalOutcomesResolved:false,queueRestored:false,
            atomicSnapshot:false,projects:rows)
    }
}
