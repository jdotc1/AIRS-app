import CryptoKit
import Darwin
import Foundation

/// Domain adapters validate their inventories and recovery references; this store
/// owns only leases, revisions, bounded spool bytes and atomic checkpoint publication.
public protocol BatchCheckpointPayload: Codable, Sendable {
    var id: UUID { get }
    var executionID: UUID { get }
    var previousExecutionID: UUID? { get }
    var checkpointRevision: UUID? { get set }
    var persistenceError: String? { get set }
    var recoveryReports: [UUID: Data] { get }
    func validateCheckpoint(pendingIDs: Set<UUID>) throws
    mutating func setRecoveryReport(_ data: Data?, for id: UUID) throws
}

public struct BatchCheckpointEntry<Payload: Sendable>: Identifiable, Sendable {
    public let id: UUID
    public let updatedAt: Date?
    public let snapshot: Payload?
    public let issue: String?
}

private struct BatchCheckpoint<Payload: Codable>: Codable {
    let version: Int
    let updatedAt: Date
    let snapshot: Payload
    let pendingReports: [String: String]
}

/// Adapted from MacScope's checkpoint-authority and generation separation.
/// A checkpoint never contains a process handle or authorizes automatic replay.
public actor BatchCheckpointStore<Payload: BatchCheckpointPayload> {
    private let root: URL
    private let entryLimit: Int
    private let recoveryLimit: Int
    private let maximumReportBytes: Int
    private let validateReport: @Sendable (Data) throws -> Void
    private var leases: [UUID: FileHandle] = [:]
    public init(root: URL, maximumBatches: Int = 64,
                maximumRecoveryBytes: Int = 128 * 1_048_576, maximumReportBytes: Int,
                validateReport: @escaping @Sendable (Data) throws -> Void) {
        self.root = root
        self.entryLimit = maximumBatches
        self.recoveryLimit = maximumRecoveryBytes
        self.maximumReportBytes = maximumReportBytes
        self.validateReport = validateReport
    }

    public func acquire(_ id: UUID, expecting generations: Set<UUID>? = nil, revision: UUID? = nil) throws {
        guard leases[id] == nil else { throw EngineError.busy }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(root)
        let inventoryLease = try lockRoot()
        defer { unlock(inventoryLease) }
        let target = folder(id)
        let count = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.count
        guard entryLimit > 0, FileManager.default.fileExists(atPath: target.path) || count < entryLimit else {
            throw ReportError.invalidContents("Batch history is full (64 batches).")
        }
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(target)
        let lock = target.appendingPathComponent(".lease")
        let fd = Darwin.open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ReportError.invalidContents("Cannot acquire batch history lease.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw EngineError.busy }
        leases[id] = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            if (generations != nil || revision != nil), FileManager.default.fileExists(atPath: target.appendingPathComponent("checkpoint.json").path) {
                let latest = try read(id, includeReports: false).snapshot
                if (generations.map { !$0.contains(latest.executionID) } ?? false) || (revision != nil && latest.checkpointRevision != revision) {
                    throw ReportError.invalidContents("Batch history changed. Reopen the latest checkpoint before continuing.")
                }
            }
        } catch { release(id); throw error }
    }

    public func release(_ id: UUID) {
        guard let file = leases.removeValue(forKey: id) else { return }
        flock(file.fileDescriptor, LOCK_UN)
        try? file.close()
    }

    @discardableResult
    public func save(_ snapshot: Payload) throws -> UUID {
        try snapshot.validateCheckpoint(pendingIDs: Set(snapshot.recoveryReports.keys))
        let temporaryLease = leases[snapshot.id] == nil
        if temporaryLease { try acquire(snapshot.id, expecting: Set([snapshot.executionID] + [snapshot.previousExecutionID].compactMap { $0 }), revision: snapshot.checkpointRevision) }
        defer { if temporaryLease { release(snapshot.id) } }
        let inventoryLease = try lockRoot()
        defer { unlock(inventoryLease) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try requireDirectory(root)
        let target = folder(snapshot.id)
        if FileManager.default.fileExists(atPath: target.appendingPathComponent("checkpoint.json").path),
           try read(snapshot.id, includeReports: false).snapshot.checkpointRevision != snapshot.checkpointRevision {
            throw ReportError.invalidContents("Stale batch checkpoint revision. Reopen history before saving.")
        }
        let existing = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard FileManager.default.fileExists(atPath: target.path) || existing.count < entryLimit else {
            throw ReportError.invalidContents("Batch history is full (64 batches). Remove a history entry before starting another.")
        }
        var spoolBytes = 0
        for directory in existing {
            try requireDirectory(directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= 18 else { throw ReportError.invalidContents("Batch checkpoint file limit exceeded.") }
            for file in files where file.lastPathComponent.hasSuffix(".report.json") {
                try rejectSymlink(file)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size >= 0, size <= maximumReportBytes else { throw ReportError.tooLarge(maximumReportBytes) }
                spoolBytes += size
            }
        }
        let reports = snapshot.recoveryReports
        let additionalBytes = reports.values.reduce(0) { $0 + $1.count }
        var replacedBytes = 0
        for key in reports.keys {
            let url = target.appendingPathComponent("\(key.uuidString).report.json")
            if FileManager.default.fileExists(atPath: url.path) {
                replacedBytes += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
        }
        guard recoveryLimit >= 0, spoolBytes - replacedBytes <= recoveryLimit - additionalBytes else {
            throw ReportError.invalidContents("Pending batch report storage is full (128 MiB). Retain or remove an older checkpoint.")
        }
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(target)
        var persisted = snapshot
        persisted.persistenceError = nil
        let revision = UUID()
        persisted.checkpointRevision = revision
        var pending: [String: String] = [:]
        for (id, data) in reports {
            guard data.count <= maximumReportBytes else { throw ReportError.tooLarge(maximumReportBytes) }
            try validateReport(data)
            let key = id.uuidString
            let url = target.appendingPathComponent("\(key).report.json")
            try rejectSymlink(url)
            try data.write(to: url, options: .atomic)
            pending[key] = checksum(data)
            try persisted.setRecoveryReport(nil, for: id)
        }
        let checkpoint = BatchCheckpoint(version: 1, updatedAt: Date(), snapshot: persisted, pendingReports: pending)
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= 524_288 else { throw ReportError.tooLarge(524_288) }
        let manifest = target.appendingPathComponent("checkpoint.json")
        try rejectSymlink(manifest)
        try data.write(to: manifest, options: .atomic)
        // Only redundant spool files are cleaned, after the new manifest commits.
        if let files = try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasSuffix(".report.json") {
                let key = String(url.lastPathComponent.dropLast(".report.json".count))
                if UUID(uuidString: key) != nil && pending[key] == nil { try? FileManager.default.removeItem(at: url) }
            }
        }
        return revision
    }

    public func metadata(_ id: UUID) throws -> Payload { try read(id, includeReports: false).snapshot }

    public func load(_ id: UUID) throws -> Payload { try read(id).snapshot }

    public func entries() throws -> [BatchCheckpointEntry<Payload>] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try requireDirectory(root)
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard folders.count <= entryLimit else { throw ReportError.invalidContents("Batch history entry limit exceeded.") }
        return folders.compactMap { url -> BatchCheckpointEntry<Payload>? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            do {
                let checkpoint = try read(id, includeReports: false)
                return BatchCheckpointEntry(id: id, updatedAt: checkpoint.updatedAt, snapshot: checkpoint.snapshot, issue: nil)
            } catch { return BatchCheckpointEntry(id: id, updatedAt: nil, snapshot: nil, issue: error.localizedDescription) }
        }.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    public func remove(_ id: UUID) throws {
        try requireDirectory(folder(id))
        try acquire(id)
        defer { release(id) }
        let inventoryLease = try lockRoot()
        defer { unlock(inventoryLease) }
        try requireDirectory(root)
        let target = folder(id)
        try requireDirectory(target)
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    private func read(_ id: UUID, includeReports: Bool = true) throws -> BatchCheckpoint<Payload> {
        try requireDirectory(root)
        let target = folder(id)
        try requireDirectory(target)
        let manifest = target.appendingPathComponent("checkpoint.json")
        try rejectSymlink(manifest)
        var checkpoint = try JSONDecoder().decode(BatchCheckpoint<Payload>.self,
            from: ReportFiles.readBounded(manifest, limit: 524_288))
        guard checkpoint.version == 1, checkpoint.snapshot.id == id,
              checkpoint.pendingReports.count <= 1 else { throw ReportError.invalidContents("Invalid batch checkpoint identity/version.") }
        var snapshot = checkpoint.snapshot
        let pendingIDs = Set(checkpoint.pendingReports.keys.compactMap(UUID.init(uuidString:)))
        guard pendingIDs.count == checkpoint.pendingReports.count, snapshot.recoveryReports.isEmpty else {
            throw ReportError.invalidContents("Invalid pending report references or embedded report bytes.")
        }
        try snapshot.validateCheckpoint(pendingIDs: pendingIDs)
        for (key, digest) in checkpoint.pendingReports {
            guard let itemID = UUID(uuidString: key) else { throw ReportError.invalidContents("Invalid pending report reference.") }
            let url = target.appendingPathComponent("\(key).report.json")
            if !includeReports { continue }
            try rejectSymlink(url)
            let data = try ReportFiles.readBounded(url, limit: maximumReportBytes)
            guard checksum(data) == digest else { throw ReportError.invalidContents("Checkpoint report bytes changed.") }
            try validateReport(data)
            try snapshot.setRecoveryReport(data, for: itemID)
        }
        checkpoint = BatchCheckpoint(version: checkpoint.version, updatedAt: checkpoint.updatedAt,
            snapshot: snapshot, pendingReports: checkpoint.pendingReports)
        return checkpoint
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func lockRoot() throws -> FileHandle {
        let url = root.appendingPathComponent(".inventory-lease")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ReportError.invalidContents("Cannot acquire batch inventory lease.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw EngineError.busy }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private func unlock(_ file: FileHandle) { flock(file.fileDescriptor, LOCK_UN); try? file.close() }
    private func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func rejectSymlink(_ url: URL) throws {
        var fresh = url; fresh.removeAllCachedResourceValues()
        if (try? fresh.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ReportError.invalidContents("Batch history cannot use symbolic-link entries.")
        }
    }
    private func requireDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        var fresh = url; fresh.removeAllCachedResourceValues()
        guard try fresh.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ReportError.invalidContents("Batch history location is not a directory.")
        }
    }
}
