import Foundation
import CryptoKit
import AIRSCore
import EntitlementDiffCore

/// A local outcome record, separate from exchange reports and executable queue state.
public struct EntitlementBatchRecord: Codable, Sendable {
    public static let maximumBytes = 524_288
    public let version: Int
    public let kind: String
    public let finishedAt: Date
    public let result: EntitlementBatchResult

    public init(result: EntitlementBatchResult, finishedAt: Date = Date()) throws {
        version = 1; kind = "airs-entitlement-batch-history"
        self.finishedAt = finishedAt; self.result = result
        try validate()
    }

    public func data() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw AIRSCore.ReportError.tooLarge(Self.maximumBytes) }
        return bytes
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw AIRSCore.ReportError.tooLarge(maximumBytes) }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate()
        return record
    }

    private func validate() throws {
        guard version == 1, kind == "airs-entitlement-batch-history", finishedAt.timeIntervalSince1970.isFinite,
              result.settled, (1...EntitlementBatchRunner.maximumPairs).contains(result.rows.count),
              Set(result.rows.map(\.id)).count == result.rows.count else { throw invalid() }
        for row in result.rows {
            guard Self.localFile(row.pair.previous), Self.localFile(row.pair.current),
                  row.pair.previous.pathExtension.lowercased() == "app",
                  row.pair.current.pathExtension.lowercased() == "app",
                  row.unretainedData == nil, row.status != .queued, row.status != .running else { throw invalid() }
            if row.status == .completed {
                guard let changed = row.changedCount, let unchanged = row.unchangedCount,
                      changed >= 0, unchanged >= 0 else { throw invalid() }
                if row.retainedReportID != nil {
                    guard row.exportedReportURL == nil, row.exportedReportSHA256 == nil else { throw invalid() }
                } else {
                    guard let url = row.exportedReportURL, Self.localFile(url),
                          let digest = row.exportedReportSHA256, digest.utf8.count == 64,
                          digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid() }
                }
            } else {
                guard row.changedCount == nil, row.unchangedCount == nil, row.retainedReportID == nil,
                      row.exportedReportURL == nil, row.exportedReportSHA256 == nil else { throw invalid() }
            }
        }
    }

    private static func localFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
    }
    private func invalid() -> AIRSCore.ReportError {
        .invalidContents("Invalid entitlement batch history. Only settled outcomes with durable completed-report references can be saved.")
    }
}

public struct EntitlementBatchHistorySummary: Sendable {
    public let batchID: UUID
    public let finishedAt: Date
    public let pairs: Int
    public let completed: Int
    public let failed: Int
    public let cancelled: Bool
}
public typealias EntitlementBatchHistoryEntry = SnapshotLibraryEntry<EntitlementBatchHistorySummary>

/// Host-independent adapter over the same immutable store used by both report libraries.
public struct EntitlementBatchHistory: Sendable {
    public let storageRoot: URL
    private let store: SnapshotLibrary<EntitlementBatchRecord>

    public init(root: URL, maximumEntries: Int = 64, maximumTotalBytes: Int = 32 * 1_048_576) {
        storageRoot = root
        store = SnapshotLibrary(root: root, maximumReportBytes: EntitlementBatchRecord.maximumBytes,
            maximumEntries: maximumEntries, maximumTotalBytes: maximumTotalBytes,
            decode: { try EntitlementBatchRecord.decode($0) })
    }
    public func keep(_ data: Data) async throws -> UUID {
        try await store.keep(data, provenance: LibraryProvenance(sourceLabel: "Entitlement batch history"))
    }
    public func load(_ id: UUID) async throws -> EntitlementBatchRecord { try await store.load(id).report }
    /// Bind selected library IDs to their admitted original bytes, not a re-encoded
    /// result batch ID. Missing membership stays absent; invalid present entries
    /// throw rather than being mislabeled as missing portable evidence.
    func portableRecords(for ids: Set<UUID>) async throws -> [UUID: Data] {
        guard ids.count <= 128 else { throw InspectionArchiveError.limit }
        try Task.checkCancellation()
        guard !ids.isEmpty else { return [:] }
        let stored = try await store.storedIDs()
        var records: [UUID: Data] = [:]
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) where stored.contains(id) {
            try Task.checkCancellation()
            // SnapshotLibrary verifies the requested receipt ID and digest and
            // returns those same decoded bytes. Repeated project links share one
            // load here; never serialize the decoded record to recover its bytes.
            records[id] = try await store.load(id).data
        }
        try Task.checkCancellation()
        return records
    }
    public func remove(_ id: UUID) async throws { try await store.remove(id) }
    public func entries() async throws -> [EntitlementBatchHistoryEntry] {
        try await store.entries { record in
            .init(batchID: record.result.id, finishedAt: record.finishedAt, pairs: record.result.rows.count,
                  completed: record.result.rows.filter { $0.status == .completed }.count,
                  failed: record.result.rows.filter { $0.status == .failed }.count, cancelled: record.result.cancelled)
        }
    }

    public static func reportDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// An exported report can be moved or replaced independently of history.
    public static func readExport(_ url: URL, expectedDigest: String) throws -> SavedReport {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try ReportFiles.readBounded(url, limit: SavedReport.maximumBytes)
        guard reportDigest(data) == expectedDigest else {
            throw AIRSCore.ReportError.invalidContents("The exported comparison changed. This history reference is unavailable; no app was reread.")
        }
        return try SavedReport.parse(data)
    }
}
