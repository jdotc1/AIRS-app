import Foundation
import Darwin
import AIRSCore

/// Reuses SnapshotLibrary's immutable bytes/receipts and capacity admission.
/// Manifest transactions adapt BatchCheckpointStore's no-follow flock and
/// MacScope's expected-parent -> parent+1 optimistic revision rule.
public actor InspectionProjectStore {
    public nonisolated let storageRoot:URL
    private let snapshots:SnapshotLibrary<InspectionArchive>
    private let maximumProjects:Int
    private let publish:@Sendable (Data,URL)throws->Void
    private struct Cached:Sendable {let bytes:Data;let digest:String;let reportStamp:ResumeFileIdentity;let receiptStamp:ResumeFileIdentity}
    private var cache:[UUID:Cached]=[:]
    public init(root:URL,maximumProjects:Int=64,maximumEvidence:Int=128,maximumEvidenceBytes:Int=268_435_456,
                publish:@escaping @Sendable (Data,URL)throws->Void={try $0.write(to:$1,options:.atomic)}) {
        storageRoot=root;self.maximumProjects=maximumProjects;self.publish=publish
        snapshots=SnapshotLibrary(root:root.appendingPathComponent("Evidence"),maximumReportBytes:InspectionArchive.maximumBytes,
            maximumEntries:maximumEvidence,maximumTotalBytes:maximumEvidenceBytes,decode:{try InspectionArchive.decode($0)})
    }
    public func create(name:String) async throws -> InspectionProject {
        let project=InspectionProject(name:name);try await save(project,expectedRevision:0);return try metadata(project.id)
    }
    public func save(_ project:InspectionProject,expectedRevision:Int) async throws {
        let lease=try lock();defer {unlock(lease)}
        try await commit(project,expectedRevision:expectedRevision,action:"metadataSaved")
    }
    public func metadata(_ id:UUID) throws -> InspectionProject {try read(id)}
    public func load(_ id:UUID) async throws -> InspectionProject {
        let lease=try lock();defer {unlock(lease)}
        let project=try read(id)
        for reference in project.evidence {_=try await checked(reference)}
        return project
    }
    public func entries() throws -> [InspectionProjectEntry] {
        try folders().map {url in
            let id=UUID(uuidString:url.lastPathComponent) ?? UUID()
            do {return .init(id:id,project:try read(id),issue:nil)} catch {return .init(id:id,project:nil,issue:error.localizedDescription)}
        }.sorted {($0.project?.updatedAt ?? .distantPast)>($1.project?.updatedAt ?? .distantPast)}
    }
    @discardableResult
    public func addEvidence(_ bytes:Data,to id:UUID,expectedRevision:Int?=nil) async throws -> InspectionProject {
        let lease=try lock();defer {unlock(lease)}
        var project=try read(id);try expect(project,expectedRevision)
        let archive=try InspectionArchive.decode(bytes),digest=AssessmentDocument.digest(bytes)
        if let existing=project.evidence.first(where:{$0.digest == digest}) {
            guard try await checked(existing) == bytes else {throw InspectionArchiveError.invalid};return project
        }
        guard project.evidence.count < 128 else {throw full()}
        // Complete fallible interpretation before retaining a new copy.
        let summary=try describe(archive)
        let retained=try await snapshots.keep(bytes,provenance:.init(sourceLabel:"Project evidence"))
        let reference=ProjectEvidenceReference(id:retained,digest:digest,savedAt:Date(),extractionTimes:summary.0,producerModels:summary.1,appVersions:summary.2,kinds:archive.attachments.map(\.kind))
        // keep already validated/wrote exact bytes. Cache only with fresh file and
        // receipt stamps; subsequent metadata edits never reopen/rehash observations.
        cache[retained]=try cached(retained,bytes,digest)
        project.evidence.append(reference);project.revision += 1
        try await commit(project,expectedRevision:project.revision-1,action:"evidenceAdded")
        return try read(id)
    }
    @discardableResult
    public func pinBaseline(_ evidenceID:UUID?,in id:UUID,expectedRevision:Int?=nil) async throws -> InspectionProject {
        let lease=try lock();defer {unlock(lease)}
        var project=try read(id);try expect(project,expectedRevision)
        if let evidenceID {
            guard let reference=project.evidence.first(where:{$0.id == evidenceID}) else {throw InspectionArchiveError.invalid}
            _=try await checked(reference)
        }
        if project.pinnedBaselineID == evidenceID {return project}
        project.pinnedBaselineID=evidenceID;project.revision += 1
        try await commit(project,expectedRevision:project.revision-1,action:evidenceID == nil ? "baselineUnpinned" : "baselinePinned")
        return try read(id)
    }
    @discardableResult
    public func addAnnotation(_ text:String,acknowledged:Bool,to id:UUID,supersedes:UUID?=nil,expectedRevision:Int?=nil) async throws -> InspectionProject {
        let lease=try lock();defer {unlock(lease)}
        var project=try read(id);try expect(project,expectedRevision)
        guard project.annotations.count < 128 else {throw full()}
        let note=ProjectAnnotation(text:text,acknowledged:acknowledged,supersedes:supersedes)
        project.annotations.append(note);project.annotationIDs.append(note.id);project.revision += 1
        try await commit(project,expectedRevision:project.revision-1,action:"annotationAdded")
        return try read(id)
    }
    public func annotations(in id:UUID) throws -> [ProjectAnnotation] {try read(id).annotations}
    @discardableResult
    public func linkBatch(_ link:ProjectBatchLink,to id:UUID,expectedRevision:Int?=nil) async throws -> InspectionProject {
        let lease=try lock();defer {unlock(lease)}
        var project=try read(id);try expect(project,expectedRevision)
        if project.batchLinks.contains(where:{$0.family == link.family && $0.historyID == link.historyID && $0.rowIDs == link.rowIDs}) {return project}
        project.batchLinks.append(link);project.revision += 1
        try await commit(project,expectedRevision:project.revision-1,action:"batchLinked")
        return try read(id)
    }
    public func removeEvidence(_ evidenceID:UUID,from id:UUID,expectedRevision:Int?=nil) async throws {
        let lease=try lock();defer {unlock(lease)}
        var project=try read(id);try expect(project,expectedRevision)
        guard project.pinnedBaselineID != evidenceID else {throw invalid("Unpin this baseline before removing project membership.")}
        guard project.evidence.contains(where:{$0.id == evidenceID}) else {throw InspectionArchiveError.invalid}
        project.evidence.removeAll{$0.id == evidenceID};project.revision += 1
        try await commit(project,expectedRevision:project.revision-1,action:"evidenceMembershipRemoved")
    }
    public func evidence(_ id:UUID) async throws -> Data {try await retained(id).bytes}
    public func evidence(_ evidenceID:UUID,in projectID:UUID) async throws -> Data {
        let lease=try lock();defer {unlock(lease)}
        guard let reference=try read(projectID).evidence.first(where:{$0.id == evidenceID}) else {throw InspectionArchiveError.invalid}
        return try await checked(reference)
    }
    public func unreferencedEvidence() async throws -> [UUID] {
        let lease=try lock();defer {unlock(lease)}
        let used=try Set(folders().flatMap {url in try readID(url).evidence.map(\.id)})
        return try await snapshots.storedIDs().subtracting(used).sorted{$0.uuidString<$1.uuidString}
    }
    public func removeRetainedEvidence(_ id:UUID) async throws {
        let lease=try lock();defer {unlock(lease)}
        guard try !folders().contains(where:{try readID($0).evidence.contains{$0.id == id}}) else {throw invalid("Evidence is still referenced by a project; remove its membership first.")}
        try await snapshots.remove(id);cache[id]=nil
    }
    public func removeProject(_ id:UUID) throws {
        let lease=try lock();defer {unlock(lease)}
        try directory(folder(id));try FileManager.default.trashItem(at:folder(id),resultingItemURL:nil)
    }
    /// Freeze one coherent project revision; reuse validated retained bytes/witnesses.
    public func exportPortableProject(_ id: UUID, to destination: URL, expectedRevision: Int? = nil) async throws {
        guard !destination.standardizedFileURL.path.hasPrefix(storageRoot.standardizedFileURL.path+"/"),destination.standardizedFileURL != storageRoot.standardizedFileURL else { throw invalid("Export outside the source project store.") }
        let lease = try lock(); defer { unlock(lease) }
        let snapshot = try manifestSnapshot(id)
        let project = snapshot.project
        try expect(project,expectedRevision)
        var evidence: [UUID:Data] = [:]
        for reference in project.evidence {
            try Task.checkCancellation()
            evidence[reference.id] = try await checked(reference)
        }
        try PortableProjectWriter.write(project: project, metadata: snapshot.bytes, evidence: evidence, to: destination)
    }

    // Only the fresh owned reconstruction stage calls this path. Existing stores
    // and revision transactions are never overwritten by a transported manifest.
    func restorePortable(_ project: InspectionProject, metadata: Data, evidence: [UUID:Data]) async throws {
        let lease = try lock(); defer { unlock(lease) }
        guard try folders().isEmpty, try await snapshots.storedIDs().isEmpty else { throw invalid("Reconstruction requires an empty staging store.") }
        try project.validate()
        for reference in project.evidence {
            try Task.checkCancellation()
            guard let bytes = evidence[reference.id] else { throw InspectionArchiveError.invalid }
            let retained = try await snapshots.keep(bytes, provenance: .init(sourceLabel:"Imported portable project evidence"), retainingID:reference.id)
            cache[retained] = try cached(retained, bytes, reference.digest)
        }
        let target = folder(project.id)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        try publish(metadata,target.appendingPathComponent("manifest.json"))
    }

    private func commit(_ proposal:InspectionProject,expectedRevision:Int,action:String) async throws {
        try proposal.validate()
        let target=folder(proposal.id).appendingPathComponent("manifest.json")
        let exists=FileManager.default.fileExists(atPath:target.path)
        let current=exists ? try read(proposal.id) : nil
        guard expectedRevision >= 0,expectedRevision < 1_000_000,
              (current?.revision ?? 0) == expectedRevision,proposal.revision == expectedRevision+1 else {throw invalid("Stale project revision. Reload before saving.")}
        if let current {
            guard proposal.createdAt == current.createdAt,proposal.history == current.history,
                  proposal.annotations.starts(with:current.annotations),proposal.batchLinks.starts(with:current.batchLinks) else {throw invalid("Existing review history cannot be rewritten.")}
            for reference in proposal.evidence {
                if let old=current.evidence.first(where:{$0.id == reference.id}) {guard old == reference else {throw invalid("Retained observation metadata cannot be rewritten.")}}
                else {_=try await checked(reference)}
            }
            if proposal.pinnedBaselineID != current.pinnedBaselineID,let id=proposal.pinnedBaselineID,
               let reference=proposal.evidence.first(where:{$0.id == id}) {_=try await checked(reference)}
        } else {
            guard try folders().count < maximumProjects else {throw full()}
            for reference in proposal.evidence {_=try await checked(reference)}
        }
        var next=proposal;next.updatedAt=Date()
        next.history.append(.init(id:UUID(),revision:proposal.revision,date:next.updatedAt,action:action))
        let bytes=try next.data()
        if current != nil {try publish(bytes,target)}
        else {
            let stage=storageRoot.appendingPathComponent("Projects/.stage-\(UUID())")
            try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
            defer {try? FileManager.default.removeItem(at:stage)}
            try publish(bytes,stage.appendingPathComponent("manifest.json"))
            try FileManager.default.moveItem(at:stage,to:folder(proposal.id))
        }
    }
    private func checked(_ reference:ProjectEvidenceReference) async throws -> Data {
        let value=try await retained(reference.id)
        guard value.digest == reference.digest else {throw invalid("Project evidence digest no longer matches its immutable reference.")};return value.bytes
    }
    private func cached(_ id:UUID,_ bytes:Data,_ digest:String) throws -> Cached {
        let root=storageRoot.appendingPathComponent("Evidence/\(id.uuidString)")
        return try .init(bytes:bytes,digest:digest,reportStamp:.capture(root.appendingPathComponent("report.json")),receiptStamp:.capture(root.appendingPathComponent("receipt.json")))
    }
    private func retained(_ id:UUID) async throws -> Cached {
        if let value=cache[id] {
            let current=try cached(id,Data(),"")
            if value.reportStamp == current.reportStamp && value.receiptStamp == current.receiptStamp {return value}
        }
        let before=try cached(id,Data(),"")
        let value=try await snapshots.load(id),digest=AssessmentDocument.digest(value.data)
        let result=try cached(id,value.data,digest)
        guard before.reportStamp == result.reportStamp,before.receiptStamp == result.receiptStamp else {
            throw invalid("Retained evidence changed while loading; reopen the original instead of using this copy.")
        }
        cache[id]=result;return result
    }
    private func describe(_ archive:InspectionArchive) throws -> ([Date],[String],[String]) {
        var dates:[Date]=[],models:[String]=[],versions:[String]=[]
        for item in archive.attachments where item.schemaVersion == 1 && item.mediaType == "application/json" {
            if item.kind == InspectionDocument.kind {
                let document=try InspectionDocumentCodec.decode(item.bytes);dates.append(document.capturedAt);models.append("extractor: "+document.producerVersion)
                if let identity=document.identity {versions += [identity.version,identity.build].compactMap{$0}.map{"app declaration: "+$0}}
            } else if item.kind == ComponentInventoryDocumentCodec.kind {
                let inventory=try ComponentInventoryDocumentCodec.decode(item.bytes);dates.append(inventory.capturedAt)
                versions += inventory.components.compactMap(\.declaredVersion).map{"app declaration: "+$0}
            } else if item.kind == "airs.audit" {
                let report=try AuditReport.decode(item.bytes);models.append("analysis model: "+report.generator.analysisModelVersion)
            } else if item.kind == AssessmentDocument.kind {
                let document=try AssessmentDocument.decode(item.bytes);dates += document.results.map(\.startedAt);models += document.results.map{"assessment API: "+$0.toolOrAPI}
            }
        }
        return (Array(Set(dates)).sorted(),Array(Set(models)).sorted(),Array(Set(versions)).sorted())
    }
    private func expect(_ project:InspectionProject,_ expected:Int?) throws {
        if let expected,project.revision != expected {throw invalid("Stale project revision. Reload before saving.")}
    }
    private func readID(_ url:URL) throws -> InspectionProject {
        guard let id=UUID(uuidString:url.lastPathComponent) else {throw InspectionArchiveError.invalid};return try read(id)
    }
    private func manifestSnapshot(_ id:UUID) throws -> (project:InspectionProject,bytes:Data) {
        try directory(storageRoot);try directory(storageRoot.appendingPathComponent("Projects"));try directory(folder(id))
        let file=folder(id).appendingPathComponent("manifest.json");try noLink(file)
        let (bytes,_)=try BoundReviewFiles.snapshot(file,limit:2_097_152)
        let project=try InspectionProject.decode(bytes)
        guard project.id == id else {throw InspectionArchiveError.invalid}
        return (project,bytes)
    }
    private func read(_ id:UUID) throws -> InspectionProject {
        try directory(storageRoot);try directory(storageRoot.appendingPathComponent("Projects"));try directory(folder(id))
        let file=folder(id).appendingPathComponent("manifest.json");try noLink(file)
        let value=try InspectionProject.decode(ReportFiles.readBounded(file,limit:2_097_152))
        guard value.id == id else {throw InspectionArchiveError.invalid};return value
    }
    private func folder(_ id:UUID) -> URL {storageRoot.appendingPathComponent("Projects/\(id.uuidString)")}
    private func folders() throws -> [URL] {
        let root=storageRoot.appendingPathComponent("Projects")
        guard FileManager.default.fileExists(atPath:root.path) else {return []};try directory(storageRoot);try directory(root)
        let values=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{UUID(uuidString:$0.lastPathComponent) != nil}
        guard values.count <= maximumProjects else {throw full()};return values
    }
    private func lock() throws -> Int32 {
        try FileManager.default.createDirectory(at:storageRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try directory(storageRoot)
        guard storageRoot.standardizedFileURL.path.utf8.elementsEqual(storageRoot.resolvingSymlinksInPath().standardizedFileURL.path.utf8) else {throw invalid("Project storage cannot use symbolic-link ancestors.")}
        let fd=Darwin.open(storageRoot.appendingPathComponent(".lease").path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd >= 0 else {throw invalid("Cannot open project lease.")}
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else {Darwin.close(fd);throw EngineError.busy}
        do {
            let projects=storageRoot.appendingPathComponent("Projects")
            try FileManager.default.createDirectory(at:projects,withIntermediateDirectories:true);try directory(projects)
            return fd
        } catch {unlock(fd);throw error}
    }
    private func unlock(_ fd:Int32) {_=flock(fd,LOCK_UN);Darwin.close(fd)}
    private func noLink(_ url:URL) throws {
        if try url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink == true {throw invalid("Project entries cannot be symbolic links.")}
    }
    private func directory(_ url:URL) throws {
        try noLink(url);guard try url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else {throw invalid("Invalid project directory.")}
    }
    private func invalid(_ text:String) -> ReportError {.invalidContents(text)}
    private func full() -> ReportError {invalid("Project/evidence retention is full. Export or explicitly remove an entry; nothing was evicted.")}
}
