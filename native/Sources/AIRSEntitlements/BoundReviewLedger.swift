import Foundation
import AIRSCore

public struct BoundReviewReceiptEntry: Identifiable, Sendable {
    public var id: UUID { acknowledgment.id }
    public let acknowledgment: BoundReviewAcknowledgment
    public let associated: Bool
}

/// Local immutable evidence retention, independent of the current audit selection.
/// IDs are validated UUIDs; no imported path or filename selects a local artifact.
public actor BoundReviewLedger {
    private let root: URL
    private struct Cached<Value: Sendable>: Sendable { let value: Value; let witness: ResumeFileIdentity }
    private var requests: [UUID:Cached<BoundReviewRequest>] = [:]
    private var receipts: [UUID:Cached<BoundReviewAcknowledgment>] = [:]
    public init(root: URL) { self.root = root }

    public func retain(_ request: BoundReviewRequest) throws {
        let url = path("requests",request.requestID,"airsreview")
        let witness = try commit(request.archiveBytes,to:url)
        requests[request.requestID] = Cached(value:request,witness:witness)
    }
    public func importArchive(_ bytes: Data) throws -> BoundReviewRequest {
        let request = try BoundReviewRequest.decodeArchive(bytes)
        try retain(request)
        return request
    }
    public func importAcknowledgment(_ bytes: Data) throws -> BoundReviewReceiptEntry {
        let acknowledgment = try BoundReviewAcknowledgment.decode(bytes)
        try prepare()
        let associated = try association(acknowledgment)
        let witness = try commit(bytes,to:path("acknowledgments",acknowledgment.id,"json"))
        receipts[acknowledgment.id] = Cached(value:acknowledgment,witness:witness)
        return .init(acknowledgment:acknowledgment,associated:associated)
    }
    public func entries() throws -> [BoundReviewReceiptEntry] {
        try prepare()
        try budget()
        return try files("acknowledgments").sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let id = try fileID(url,ext:"json")
            let receipt: BoundReviewAcknowledgment
            let current = try ResumeFileIdentity.capture(url)
            if let cached = receipts[id],cached.witness == current { receipt = cached.value }
            else {
                let (bytes,witness) = try BoundReviewFiles.snapshot(url,limit:1_048_576)
                receipt = try BoundReviewAcknowledgment.decode(bytes)
                guard receipt.id == id else { throw BoundReviewError.invalid("Retained acknowledgment ID mismatch.") }
                receipts[id] = Cached(value:receipt,witness:witness)
            }
            return .init(acknowledgment:receipt,associated:try association(receipt))
        }
    }
    private func association(_ acknowledgment: BoundReviewAcknowledgment) throws -> Bool {
        guard let id = acknowledgment.requestID else { return false }
        let url = path("requests",id,"airsreview")
        guard FileManager.default.fileExists(atPath:url.path) else { requests[id] = nil; return false }
        _ = try fileID(url,ext:"airsreview")
        let current = try ResumeFileIdentity.capture(url)
        if let cached = requests[id],cached.witness == current { return try acknowledgment.matches(cached.value) }
        let (bytes,witness) = try BoundReviewFiles.snapshot(url,limit:InspectionArchive.maximumBytes)
        let request = try BoundReviewRequest.decodeArchive(bytes)
        guard request.requestID == id else { throw BoundReviewError.invalid("Retained request ID mismatch.") }
        requests[id] = Cached(value:request,witness:witness)
        return try acknowledgment.matches(request)
    }
    private func path(_ folder: String,_ id: UUID,_ ext: String) -> URL {
        root.appendingPathComponent(folder,isDirectory:true).appendingPathComponent(id.uuidString.lowercased()+"."+ext)
    }
    private func prepare() throws {
        for url in [root,root.appendingPathComponent("requests"),root.appendingPathComponent("acknowledgments")] {
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let info = try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard url.standardizedFileURL.path.utf8.elementsEqual(url.resolvingSymlinksInPath().standardizedFileURL.path.utf8),info.isDirectory == true,info.isSymbolicLink != true else { throw BoundReviewError.invalid("Evidence storage must be a local directory.") }
        }
    }
    private func budget() throws {
        let requests = try files("requests"), receipts = try files("acknowledgments")
        guard requests.count <= 32,receipts.count <= 128 else { throw InspectionArchiveError.limit }
        var total: Int64 = 0
        for (items,ext) in [(requests,"airsreview"),(receipts,"json")] {
            for file in items {
                _ = try fileID(file,ext:ext)
                let witness = try ResumeFileIdentity.capture(file)
                guard witness.size >= 0,witness.size <= 128 * 1_048_576-total else { throw InspectionArchiveError.limit }
                total += witness.size
            }
        }
    }
    private func files(_ folder: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent(folder),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
    }
    private func fileID(_ url: URL,ext: String) throws -> UUID {
        let info = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
        guard info.isRegularFile == true,info.isSymbolicLink != true,url.pathExtension == ext,
              let id = UUID(uuidString:url.deletingPathExtension().lastPathComponent) else { throw BoundReviewError.invalid("Unexpected retained evidence file.") }
        return id
    }
    private func commit(_ bytes: Data,to url: URL) throws -> ResumeFileIdentity {
        try prepare()
        try budget()
        let requests = try files("requests"), receipts = try files("acknowledgments")
        var total = 0
        for file in requests+receipts {
            _ = try fileID(file,ext:file.pathExtension == "airsreview" ? "airsreview" : "json")
            total += try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        }
        if FileManager.default.fileExists(atPath:url.path) {
            _ = try fileID(url,ext:url.pathExtension)
            let (retained,witness) = try BoundReviewFiles.snapshot(url,limit:InspectionArchive.maximumBytes)
            guard retained == bytes else {
                throw BoundReviewError.invalid("Conflicting bytes for an existing evidence ID; the original was preserved.")
            }
            return witness
        }
        guard total <= 128 * 1_048_576 - bytes.count,
              url.pathExtension == "airsreview" ? requests.count < 32 : receipts.count < 128 else { throw InspectionArchiveError.limit }
        // Exclusive creation prevents an existing file from being replaced, including
        // a competing writer's receipt. Original source files are never destinations.
        try bytes.write(to:url,options:.withoutOverwriting)
        let (retained,witness) = try BoundReviewFiles.snapshot(url,limit:InspectionArchive.maximumBytes)
        guard retained == bytes else { throw BoundReviewError.invalid("Evidence changed during retention.") }
        return witness
    }
}
