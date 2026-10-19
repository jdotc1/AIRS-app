import Foundation
import AIRSCore
import EntitlementDiffCore

/// Explicit ordered selections. Paths may be kept in local history, never exchange reports.
public struct EntitlementBatchPair: Identifiable, Codable, Sendable {
    public let id: UUID
    public let previous: URL
    public let current: URL
    public let architecture: Architecture

    public init(id: UUID = UUID(), previous: URL, current: URL, architecture: Architecture) {
        self.id = id; self.previous = previous; self.current = current; self.architecture = architecture
    }

    private enum CodingKeys: String, CodingKey { case id, previous, current, architecture }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        previous = try fields.decode(URL.self, forKey: .previous)
        current = try fields.decode(URL.self, forKey: .current)
        let raw = try fields.decode(String.self, forKey: .architecture)
        guard let value = Architecture(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .architecture, in: fields,
                debugDescription: "Unsupported requested architecture in batch history.")
        }
        architecture = value
    }
}

public enum EntitlementBatchStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, notStarted, duplicate
    public var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Comparing"
        case .completed: "Comparison completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .notStarted: "Not started"
        case .duplicate: "Duplicate pair skipped"
        }
    }
}

public struct EntitlementBatchRow: Identifiable, Codable, Sendable {
    public var id: UUID { pair.id }
    public let pair: EntitlementBatchPair
    public var status: EntitlementBatchStatus
    public var message: String
    public var changedCount: Int?
    public var unchangedCount: Int?
    public var retainedReportID: UUID?
    public var exportedReportURL: URL?
    public var exportedReportSHA256: String?
    /// At most one complete result needs recovery; the queue stops on save failure.
    public var unretainedData: Data?
}

public struct EntitlementBatchResult: Identifiable, Codable, Sendable {
    public let id: UUID
    public var rows: [EntitlementBatchRow]
    public var settled: Bool
    public var cancelled: Bool
    public var hasUnretainedReport: Bool { rows.contains { $0.unretainedData != nil } }
}

public enum EntitlementBatchError: Error, LocalizedError, Sendable {
    case busy, invalidPlan, limit
    public var errorDescription: String? {
        switch self {
        case .busy: "An entitlement batch is already running."
        case .invalidPlan: "Choose 1–16 explicit pairs of local .app paths with unique row IDs."
        case .limit: "The complete entitlement report exceeds the batch report-byte budget. It was not truncated or retained."
        }
    }
}

/// Adapted from AIRS ImageBatchRunner's bounded serial queue and retention boundary,
/// originally informed by MacScope's reconstruction scheduler. No UI or scene state.
public actor EntitlementBatchRunner {
    public static let maximumPairs = 16
    public static let maximumTotalBytes = 128 * 1_048_576
    private var active = false
    private let maximumReportBytes: Int
    private let maximumTotalBytes: Int

    public init(maximumReportBytes: Int = SavedReport.maximumBytes,
                maximumTotalBytes: Int = EntitlementBatchRunner.maximumTotalBytes) {
        self.maximumReportBytes = maximumReportBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    private static func isLocalApp(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return false }
        return url.host == nil || url.host == "" || url.host == "localhost"
    }

    public func run(
        pairs: [EntitlementBatchPair], id: UUID = UUID(), reader: any SnapshotReading,
        capture: @Sendable (URL) throws -> BatchInputIdentity = { try BatchInputIdentity.capture($0) },
        retain: @Sendable (Data) async throws -> UUID,
        progress: @Sendable (EntitlementBatchResult) async -> Void = { _ in }
    ) async throws -> EntitlementBatchResult {
        try await execute(pairs: pairs, id: id, reader: reader, capture: capture,
            context: nil, resuming: nil, retain: retain, checkpoint: { _ in nil },
            progress: { await progress($0.result) }).result
    }

    public func runRecoverable(
        pairs: [EntitlementBatchPair], id: UUID = UUID(), reader: any SnapshotReading,
        capture: @Sendable (URL) throws -> BatchInputIdentity = { try BatchInputIdentity.capture($0) },
        context: EntitlementReaderContext, resuming: EntitlementBatchCheckpoint? = nil,
        retain: @Sendable (Data) async throws -> UUID,
        checkpoint: @Sendable (EntitlementBatchCheckpoint) async throws -> UUID?,
        progress: @Sendable (EntitlementBatchCheckpoint) async -> Void = { _ in }
    ) async throws -> EntitlementBatchCheckpoint {
        try await execute(pairs: pairs, id: id, reader: reader, capture: capture, context: context,
            resuming: resuming, retain: retain, checkpoint: checkpoint, progress: progress)
    }

    private func execute(
        pairs: [EntitlementBatchPair], id: UUID, reader: any SnapshotReading,
        capture: @Sendable (URL) throws -> BatchInputIdentity,
        context: EntitlementReaderContext?, resuming: EntitlementBatchCheckpoint?,
        retain: @Sendable (Data) async throws -> UUID,
        checkpoint: @Sendable (EntitlementBatchCheckpoint) async throws -> UUID?,
        progress: @Sendable (EntitlementBatchCheckpoint) async -> Void
    ) async throws -> EntitlementBatchCheckpoint {
        guard !active else { throw EntitlementBatchError.busy }
        guard !pairs.isEmpty, pairs.count <= Self.maximumPairs,
              Set(pairs.map(\.id)).count == pairs.count,
              pairs.allSatisfy({ Self.isLocalApp($0.previous) && Self.isLocalApp($0.current) }),
              maximumReportBytes > 0, maximumReportBytes <= SavedReport.maximumBytes,
              maximumTotalBytes >= maximumReportBytes else { throw EntitlementBatchError.invalidPlan }
        active = true
        defer { active = false }

        struct PairKey: Hashable {
            let previous: Data
            let current: Data
            let architecture: String
        }
        var seen = Set<PairKey>()
        let rows = pairs.map { pair in
            let key = PairKey(previous: Data(pair.previous.resolvingSymlinksInPath().standardizedFileURL.path.utf8),
                current: Data(pair.current.resolvingSymlinksInPath().standardizedFileURL.path.utf8), architecture: pair.architecture.rawValue)
            let duplicate = !seen.insert(key).inserted
            return EntitlementBatchRow(pair: pair, status: duplicate ? .duplicate : .queued,
                message: duplicate ? "This ordered pair and architecture already appear in the queue." : "Waiting for its turn.")
        }
        var state = EntitlementBatchCheckpoint(version: 1,
            result: EntitlementBatchResult(id: id, rows: rows, settled: false, cancelled: false),
            executionID: id, context: context,
            admissions: pairs.map { EntitlementPairAdmission(id: $0.id) })
        if let previous = resuming {
            try previous.validateCheckpoint(pendingIDs: Set(previous.recoveryReports.keys))
            guard context != nil, previous.context == context, previous.result.settled,
                  previous.persistenceError == nil, !previous.needsReportRecovery,
                  previous.hasRemainingPairs, previous.result.rows.count == pairs.count,
                  zip(previous.result.rows, pairs).allSatisfy({ old, pair in
                      old.id == pair.id && old.pair.previous == pair.previous && old.pair.current == pair.current && old.pair.architecture == pair.architecture
                  }), previous.admissions.allSatisfy({ $0.attempts.count < EntitlementBatchCheckpoint.maximumAttempts }) else {
                throw AIRSCore.ReportError.invalidContents("Resume requires the original reader context, saved checkpoint, recovered reports and remaining pairs within the attempt limit. Start a new explicit batch if the reader changed.")
            }
            state = previous
            state.previousExecutionID = previous.executionID; state.executionID = id
            state.result.settled = false; state.result.cancelled = false
            state.finishedAt = nil; state.historyRecordID = nil
            for index in state.result.rows.indices where [.queued, .cancelled, .notStarted].contains(state.result.rows[index].status) {
                let row = state.result.rows[index]
                state.admissions[index].attempts.append(.init(status: row.status, message: row.message, date: Date()))
                state.result.rows[index].status = .queued
                state.result.rows[index].message = "Explicitly resumed; earlier outcome preserved in attempts."
            }
        } else {
            // Capture both original identities once; resume never replaces them.
            for index in state.result.rows.indices where state.result.rows[index].status == .queued {
                do {
                    state.admissions[index].previous = try capture(pairs[index].previous)
                    state.admissions[index].current = try capture(pairs[index].current)
                } catch {
                    state.result.rows[index].status = .failed
                    state.result.rows[index].message = "Input admission failed: \(error.localizedDescription)"
                }
            }
        }
        func publish(_ value: EntitlementBatchCheckpoint) async -> (String?, UUID?) {
            await progress(value)
            do { return (nil, try await checkpoint(value)) }
            catch { return ("Recovery checkpoint could not be saved: \(error.localizedDescription)", nil) }
        }
        let admission = await publish(state)
        state.persistenceError = admission.0
        state.checkpointRevision = admission.1 ?? state.checkpointRevision
        var totalBytes = state.admissions.reduce(0) { $0 + $1.reportByteCount }
        var stopReason = admission.0
        for index in state.result.rows.indices where state.result.rows[index].status == .queued {
            if Task.isCancelled { stopReason = "Cancelled before this pair started."; state.result.cancelled = true }
            if stopReason == nil, totalBytes > maximumTotalBytes - maximumReportBytes {
                stopReason = "Batch report-byte budget reached. Completed comparisons remain saved."
            }
            if let stopReason {
                state.result.rows[index].status = .notStarted; state.result.rows[index].message = stopReason
                continue
            }
            let pair = state.result.rows[index].pair
            state.result.rows[index].status = .running
            state.result.rows[index].message = "Reading Previous, then Current; requested architecture only."
            let starting = await publish(state)
            state.checkpointRevision = starting.1 ?? state.checkpointRevision
            if let issue = starting.0 {
                state.persistenceError = issue; stopReason = issue
                state.result.rows[index].status = .notStarted; state.result.rows[index].message = issue
                continue
            }
            do {
                try Task.checkCancellation()
                guard let previousIdentity = state.admissions[index].previous,
                      let currentIdentity = state.admissions[index].current,
                      try capture(pair.previous) == previousIdentity, try capture(pair.current) == currentIdentity else {
                    throw AIRSCore.ReportError.invalidContents("Selected app changed since batch admission. It was not inspected; select it in a new batch.")
                }
                let previous = try await reader.read(at: pair.previous, architecture: pair.architecture)
                try Task.checkCancellation()
                guard previous.architecture == pair.architecture else { throw EntitlementDiffCore.ReportError.architectureMismatch }
                let current = try await reader.read(at: pair.current, architecture: pair.architecture)
                try Task.checkCancellation()
                guard current.architecture == pair.architecture else { throw EntitlementDiffCore.ReportError.architectureMismatch }
                guard try capture(pair.previous) == previousIdentity, try capture(pair.current) == currentIdentity else {
                    throw AIRSCore.ReportError.invalidContents("Selected app changed during comparison. No completed report admitted.")
                }
                let report = try EntitlementDiffCore.ComparisonReport(previous: previous, current: current)
                let data = try report.jsonData()
                guard data.count <= maximumReportBytes, data.count <= maximumTotalBytes - totalBytes else { throw EntitlementBatchError.limit }
                _ = try SavedReport.parse(data)
                try Task.checkCancellation()
                totalBytes += data.count
                state.admissions[index].reportByteCount = data.count
                state.result.rows[index].changedCount = report.changes.count
                state.result.rows[index].unchangedCount = report.unchangedCount
                state.result.rows[index].status = .completed
                state.result.rows[index].unretainedData = data
                state.result.rows[index].message = "Complete report awaiting retention."
                // Durable complete bytes precede the library commit. Never rerun this row.
                let completed = await publish(state)
                state.checkpointRevision = completed.1 ?? state.checkpointRevision
                if let issue = completed.0 { state.persistenceError = issue; stopReason = issue; continue }
                do {
                    state.result.rows[index].retainedReportID = try await retain(data)
                    state.result.rows[index].unretainedData = nil
                    state.result.rows[index].message = "Complete comparison retained in the entitlement library."
                } catch {
                    state.result.rows[index].message = "Compared, but not saved: \(error.localizedDescription) The complete report is preserved; queue stopped."
                    stopReason = "Not started because a completed comparison needs saving."
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    state.result.rows[index].status = .cancelled
                    state.result.rows[index].message = "Read settled after cancellation; no completed result admitted."
                    state.result.cancelled = true; stopReason = "Cancelled before this pair started."
                } else {
                    state.result.rows[index].status = .failed; state.result.rows[index].message = error.localizedDescription
                }
            }
            let outcome = await publish(state)
            state.checkpointRevision = outcome.1 ?? state.checkpointRevision
            if let issue = outcome.0 { state.persistenceError = issue; stopReason = issue }
        }
        state.result.cancelled = state.result.cancelled || Task.isCancelled
        state.result.settled = true; state.finishedAt = Date()
        let final = await publish(state)
        state.checkpointRevision = final.1 ?? state.checkpointRevision
        state.persistenceError = final.0
        await progress(state)
        return state
    }
}
