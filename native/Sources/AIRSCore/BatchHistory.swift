import CryptoKit
import Darwin
import Foundation

/// A filesystem change detector, not a content digest or an unwind identity.
public struct ResumeFileIdentity: Codable, Equatable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let changedSeconds: Int64
    public let changedNanos: Int64

    public static func capture(_ url: URL) throws -> Self {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var info = stat()
        guard path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &info, 0) }) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ReportError.invalidContents("Resume input is missing or not a regular file: \(path)")
        }
        return Self(path: path, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino, size: info.st_size,
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
}

public struct BatchInputIdentity: Codable, Equatable, Sendable {
    public let files: [ResumeFileIdentity]

    public static func capture(_ input: URL) throws -> Self {
        if input.pathExtension.lowercased() == "app" {
            let plist = input.appendingPathComponent("Contents/Info.plist")
            let bytes = try ReportFiles.readBounded(plist, limit: 1_048_576)
            guard let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let name = object["CFBundleExecutable"] as? String,
                  !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                throw ReportError.invalidContents("App has no bounded principal executable name.")
            }
            return Self(files: try [ResumeFileIdentity.capture(plist),
                ResumeFileIdentity.capture(input.appendingPathComponent("Contents/MacOS/\(name)"))])
        }
        return Self(files: try [ResumeFileIdentity.capture(input)])
    }
}

public struct BatchExecutionContext: Codable, Equatable, Sendable {
    public let policy: String
    public let files: [ResumeFileIdentity]

    public static func capture(_ configuration: EngineConfiguration) throws -> Self {
        let source = configuration.bootstrap.deletingLastPathComponent().appendingPathComponent("src/airs")
        let sources = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "py" }.sorted { $0.path < $1.path }
        guard sources.count <= 128 else { throw ReportError.invalidContents("Engine source inventory exceeds resume limit.") }
        return Self(policy: "audit-default/batch-v2/16-images/64MiB-output/128MiB-total",
            files: try ([configuration.pythonExecutable, configuration.bootstrap] + sources).map(ResumeFileIdentity.capture))
    }
}

public struct ImageBatchAttempt: Codable, Sendable {
    public let status: ImageBatchStatus
    public let message: String
    public let date: Date
}

public typealias BatchHistoryEntry = BatchCheckpointEntry<ImageBatchSnapshot>

/// Audit adapter preserves its public operations and version-1 checkpoint shape.
public struct BatchHistory: Sendable {
    public static let maximumBatches = 64
    private let store: BatchCheckpointStore<ImageBatchSnapshot>
    public init(root: URL, maximumBatches: Int = BatchHistory.maximumBatches,
                maximumRecoveryBytes: Int = 128 * 1_048_576) {
        store = BatchCheckpointStore(root: root, maximumBatches: maximumBatches,
            maximumRecoveryBytes: maximumRecoveryBytes, maximumReportBytes: ReportFiles.maximumBytes,
            validateReport: { _ = try AuditReport.decode($0) })
    }
    public func acquire(_ id: UUID, expecting generations: Set<UUID>? = nil, revision: UUID? = nil) async throws {
        try await store.acquire(id, expecting: generations, revision: revision)
    }
    public func release(_ id: UUID) async { await store.release(id) }
    @discardableResult
    public func save(_ snapshot: ImageBatchSnapshot) async throws -> UUID { try await store.save(snapshot) }
    public func metadata(_ id: UUID) async throws -> ImageBatchSnapshot { try await store.metadata(id) }
    public func load(_ id: UUID) async throws -> ImageBatchSnapshot { try await store.load(id) }
    public func entries() async throws -> [BatchHistoryEntry] { try await store.entries() }
    public func remove(_ id: UUID) async throws { try await store.remove(id) }
}

extension ImageBatchSnapshot: BatchCheckpointPayload {
    public var recoveryReports: [UUID: Data] {
        items.reduce(into: [:]) { if let data = $1.unretainedData { $0[$1.id] = data } }
    }
    public func validateCheckpoint(pendingIDs: Set<UUID>) throws {
        guard !items.isEmpty, items.count <= 16,
              Set(items.map(\.id)).count == items.count,
              items.filter({ $0.unretainedData != nil }).count <= 1, pendingIDs.count <= 1,
              items.allSatisfy({ $0.input.isFileURL && $0.attempts.count <= 16 && $0.reportByteCount >= 0 && $0.reportByteCount <= ReportFiles.maximumBytes }),
              items.reduce(0, { $0 + $1.reportByteCount }) <= 128 * 1_048_576,
              pendingIDs.allSatisfy({ id in items.contains { $0.id == id && $0.status == .completed && $0.retainedReportID == nil } }) else {
            throw ReportError.invalidContents("Invalid or oversized batch inventory.")
        }
    }
    public mutating func setRecoveryReport(_ data: Data?, for id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id && $0.status == .completed && $0.retainedReportID == nil }) else {
            throw ReportError.invalidContents("Invalid pending report reference.")
        }
        items[index].unretainedData = data
    }
}
