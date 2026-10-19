import Foundation
import AIRSCore
import EntitlementDiffCore

public struct EntitlementReaderContext: Codable, Equatable, Sendable {
    public static let currentPolicy = "entitlements/main-executable/requested-architecture/schema-1/resume-v1"
    public let policy: String
    public let operatingSystem: String
    public let executable: ResumeFileIdentity

    public static func capture(executable: URL) throws -> Self {
        Self(policy: currentPolicy, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
             executable: try ResumeFileIdentity.capture(executable))
    }
}

public struct EntitlementBatchAttempt: Codable, Sendable {
    public let status: EntitlementBatchStatus
    public let message: String
    public let date: Date
}

public struct EntitlementPairAdmission: Codable, Sendable {
    public let id: UUID
    public var previous: BatchInputIdentity?
    public var current: BatchInputIdentity?
    public var reportByteCount = 0
    public var attempts: [EntitlementBatchAttempt] = []
}

/// Mutable recovery state is independent of immutable settled outcome history.
public struct EntitlementBatchCheckpoint: BatchCheckpointPayload {
    public static let maximumAttempts = 16
    public let version: Int
    public var id: UUID { result.id }
    public var result: EntitlementBatchResult
    public var executionID: UUID
    public var previousExecutionID: UUID?
    public var checkpointRevision: UUID?
    public var persistenceError: String?
    public let context: EntitlementReaderContext?
    public var admissions: [EntitlementPairAdmission]
    public var finishedAt: Date?
    public var historyRecordID: UUID?

    public var recoveryReports: [UUID: Data] {
        result.rows.reduce(into: [:]) { if let data = $1.unretainedData { $0[$1.id] = data } }
    }
    public var needsReportRecovery: Bool {
        result.rows.contains { $0.status == .completed && $0.retainedReportID == nil && $0.exportedReportURL == nil }
    }
    public var hasRemainingPairs: Bool {
        result.rows.contains { [.queued, .cancelled, .notStarted].contains($0.status) }
    }

    public func validateCheckpoint(pendingIDs: Set<UUID>) throws {
        guard version == 1, let context, !context.policy.isEmpty,
              (1...16).contains(result.rows.count), Set(result.rows.map(\.id)).count == result.rows.count,
              admissions.map(\.id) == result.rows.map(\.id), pendingIDs.count <= 1,
              pendingIDs.isSubset(of: Set(result.rows.map(\.id))),
              admissions.allSatisfy({ $0.attempts.count <= Self.maximumAttempts && $0.reportByteCount >= 0 && $0.reportByteCount <= SavedReport.maximumBytes }),
              admissions.reduce(0, { $0 + $1.reportByteCount }) <= EntitlementBatchRunner.maximumTotalBytes,
              !result.settled || !result.rows.contains(where: { [.queued, .running].contains($0.status) }),
              finishedAt == nil || result.settled else { throw invalid() }
        for (row, admission) in zip(result.rows, admissions) {
            for url in [row.pair.previous, row.pair.current] {
                guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                      url.pathExtension.lowercased() == "app" else { throw invalid() }
            }
            if row.status == .completed {
                guard let changed = row.changedCount, changed >= 0,
                      let unchanged = row.unchangedCount, unchanged >= 0,
                      admission.reportByteCount > 0 else { throw invalid() }
                let references = (row.retainedReportID == nil ? 0 : 1) + (row.exportedReportURL == nil ? 0 : 1) + (pendingIDs.contains(row.id) ? 1 : 0)
                guard references == 1 else { throw invalid() }
                if let data = row.unretainedData {
                    guard pendingIDs.contains(row.id), data.count == admission.reportByteCount else { throw invalid() }
                }
                if let url = row.exportedReportURL {
                    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                          let digest = row.exportedReportSHA256, digest.utf8.count == 64,
                          digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid() }
                } else if row.exportedReportSHA256 != nil { throw invalid() }
            } else {
                guard row.changedCount == nil, row.unchangedCount == nil, admission.reportByteCount == 0,
                      row.retainedReportID == nil, row.exportedReportURL == nil, row.exportedReportSHA256 == nil,
                      row.unretainedData == nil, !pendingIDs.contains(row.id) else { throw invalid() }
            }
            if [.queued, .running, .cancelled, .notStarted, .completed].contains(row.status) {
                guard admission.previous != nil, admission.current != nil else { throw invalid() }
            }
        }
        if historyRecordID != nil {
            guard result.settled, finishedAt != nil, !needsReportRecovery else { throw invalid() }
        }
    }

    public mutating func setRecoveryReport(_ data: Data?, for id: UUID) throws {
        guard let index = result.rows.firstIndex(where: { $0.id == id && $0.status == .completed && $0.retainedReportID == nil && $0.exportedReportURL == nil }) else { throw invalid() }
        if let data, data.count != admissions[index].reportByteCount { throw invalid() }
        result.rows[index].unretainedData = data
    }

    private func invalid() -> AIRSCore.ReportError { .invalidContents("Invalid entitlement recovery checkpoint or completed-report reference.") }

    /// Call only while holding a lease after reloading the authoritative checkpoint.
    public mutating func markInterrupted() {
        guard !result.settled else { return }
        for index in result.rows.indices where result.rows[index].status == .running {
            result.rows[index].status = .cancelled
            result.rows[index].message = "Interrupted before a completed report was checkpointed. Outcome unknown; explicit resume may reread this pair."
            result.cancelled = true
        }
        for index in result.rows.indices where result.rows[index].status == .queued {
            result.rows[index].status = .notStarted
            result.rows[index].message = "Not started before interruption."
        }
        result.settled = true; finishedAt = Date()
    }
}

public typealias EntitlementRecoveryEntry = BatchCheckpointEntry<EntitlementBatchCheckpoint>

public struct EntitlementBatchRecovery: Sendable {
    public let storageRoot: URL
    private let store: BatchCheckpointStore<EntitlementBatchCheckpoint>
    public init(root: URL, maximumBatches: Int = 64, maximumRecoveryBytes: Int = 128 * 1_048_576) {
        storageRoot = root
        store = BatchCheckpointStore(root: root, maximumBatches: maximumBatches,
            maximumRecoveryBytes: maximumRecoveryBytes, maximumReportBytes: SavedReport.maximumBytes,
            validateReport: { _ = try SavedReport.parse($0) })
    }
    public func acquire(_ id: UUID, expecting generations: Set<UUID>? = nil, revision: UUID? = nil) async throws {
        try await store.acquire(id, expecting: generations, revision: revision)
    }
    public func release(_ id: UUID) async { await store.release(id) }
    public func save(_ value: EntitlementBatchCheckpoint) async throws -> UUID { try await store.save(value) }
    public func load(_ id: UUID) async throws -> EntitlementBatchCheckpoint { try await store.load(id) }
    public func entries() async throws -> [EntitlementRecoveryEntry] { try await store.entries() }
    public func remove(_ id: UUID) async throws { try await store.remove(id) }

    public func recover(_ expected: EntitlementBatchCheckpoint) async throws -> EntitlementBatchCheckpoint {
        try await acquire(expected.id, expecting: [expected.executionID], revision: expected.checkpointRevision)
        do {
            var latest = try await load(expected.id)
            if !latest.result.settled {
                latest.markInterrupted()
                latest.checkpointRevision = try await save(latest)
            }
            await release(expected.id)
            return latest
        } catch { await release(expected.id); throw error }
    }
}
