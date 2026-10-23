import Foundation
import AIRSCore

/// Explicit absence is review information, never permission to restore a queue.
public enum PortableBatchAbsence: String, Codable, Sendable {
    case missing, unsettled, incomplete, unsupportedFamily
}

public struct PortableBatchOutcome: Sendable {
    public struct Row: Sendable {
        public let id: UUID
        public let status: EntitlementBatchStatus
        public let message: String
        public let requestedArchitecture: String
        public let changedCount: Int?
        public let unchangedCount: Int?
        /// This increment transports outcomes, not referenced comparison reports.
        public let reportIncluded: Bool
    }
    public let link: ProjectBatchLink
    public let absence: PortableBatchAbsence?
    public let batchID: UUID?
    public let cancelled: Bool?
    public let finishedAt: Date?
    public let rows: [Row]
}

/// Immutable, detached history. No execution snapshot or input URL is exposed.
public struct PortableSettledBatchEvidence: Sendable {
    public static let maximumBytes = 16 * 1_048_576
    public let outcomes: [PortableBatchOutcome]
    public let originalBytes: Data
    private struct Entry: Codable {
        let linkID: UUID
        let absence: PortableBatchAbsence?
        let record: Data?
    }
    private struct Envelope: Codable {
        let kind: String
        let schemaVersion: Int
        let projectID: UUID
        let entries: [Entry]
    }

    /// History IDs are local library identities, distinct from result batch IDs.
    /// Callers supply original bytes; unavailable records are never synthesized.
    public static func prepare(project: InspectionProject, records: [UUID: Data],
                               unavailable: [UUID: PortableBatchAbsence] = [:]) throws -> Self {
        try project.validate()
        let supported = Set(project.batchLinks.filter { $0.family == .entitlements }.map(\.historyID))
        guard Set(records.keys).isSubset(of: supported), Set(unavailable.keys).isSubset(of: supported),
              Set(records.keys).isDisjoint(with: unavailable.keys),
              !unavailable.values.contains(.unsupportedFamily) else { throw InspectionArchiveError.invalid }
        var total = 0
        let entries = try project.batchLinks.map { link -> Entry in
            guard link.family == .entitlements else {
                return Entry(linkID: link.id, absence: .unsupportedFamily, record: nil)
            }
            if let bytes = records[link.historyID] {
                guard bytes.count <= EntitlementBatchRecord.maximumBytes,
                      bytes.count <= maximumBytes / 2 - total else { throw InspectionArchiveError.limit }
                total += bytes.count
                return Entry(linkID: link.id, absence: nil, record: bytes)
            }
            return Entry(linkID: link.id, absence: unavailable[link.historyID] ?? .missing, record: nil)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Envelope(kind: "airs.settled-batch-evidence", schemaVersion: 1,
                                               projectID: project.id, entries: entries))
        return try decode(bytes, project: project)
    }

    public static func decode(_ bytes: Data, project: InspectionProject) throws -> Self {
        try project.validate()
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw InspectionArchiveError.limit }
        let root = try BoundJSON.object(BoundJSON.parse(bytes), keys: ["kind", "schemaVersion", "projectID", "entries"])
        guard try BoundJSON.text(root["kind"]) == "airs.settled-batch-evidence",
              try BoundJSON.integer(root["schemaVersion"]) == 1,
              try BoundJSON.uuid(root["projectID"]) == project.id,
              case .array(let nodes) = root["entries"], nodes.count == project.batchLinks.count else { throw InspectionArchiveError.invalid }
        for node in nodes {
            let entry = try BoundJSON.object(node)
            guard Set(entry.keys) == ["linkID", "absence"] || Set(entry.keys) == ["linkID", "record"] else { throw InspectionArchiveError.invalid }
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        var records: [UUID: Data] = [:]
        var absences: [UUID: PortableBatchAbsence] = [:]
        let outcomes = try zip(envelope.entries, project.batchLinks).map { entry, link -> PortableBatchOutcome in
            guard entry.linkID == link.id else { throw InspectionArchiveError.invalid }
            if let absence = entry.absence {
                guard entry.record == nil, (link.family == .audit) == (absence == .unsupportedFamily) else { throw InspectionArchiveError.invalid }
                if link.family == .entitlements {
                    guard records[link.historyID] == nil else { throw InspectionArchiveError.invalid }
                    if let prior = absences[link.historyID], prior != absence { throw InspectionArchiveError.invalid }
                    absences[link.historyID] = absence
                }
                return PortableBatchOutcome(link: link, absence: absence, batchID: nil, cancelled: nil, finishedAt: nil, rows: [])
            }
            guard link.family == .entitlements, absences[link.historyID] == nil, let data = entry.record else { throw InspectionArchiveError.invalid }
            // Repeated links to one history identity must carry identical bytes.
            if let previous = records[link.historyID], previous != data { throw InspectionArchiveError.invalid }
            records[link.historyID] = data
            let record = try EntitlementBatchRecord.decode(data)
            let ids = Set(record.result.rows.map(\.id))
            guard Set(link.rowIDs).isSubset(of: ids) else { throw InspectionArchiveError.invalid }
            let selected = link.rowIDs.isEmpty ? record.result.rows : record.result.rows.filter { link.rowIDs.contains($0.id) }
            return PortableBatchOutcome(link: link, absence: nil, batchID: record.result.id,
                cancelled: record.result.cancelled, finishedAt: record.finishedAt, rows: selected.map {
                    .init(id: $0.id, status: $0.status, message: $0.message, requestedArchitecture: $0.pair.architecture.rawValue, changedCount: $0.changedCount,
                          unchangedCount: $0.unchangedCount, reportIncluded: false)
                })
        }
        return Self(outcomes: outcomes, originalBytes: bytes)
    }
}

public struct PortableSettledBatchAdmission: Sendable {
    public let project: PortableProjectAdmission
    public let history: PortableSettledBatchEvidence
    fileprivate let root: URL
    fileprivate let historyStamp: ResumeFileIdentity
}

/// Opt-in companion format. Existing .airsproject readers and writers are unchanged.
public enum PortableSettledBatchProject {
    private static let historyName = "settled-batches.json"
    private static let projectName = "project.airsproject"
    public static func prepare(at root: URL) throws -> PortableSettledBatchAdmission {
        try PortableProjectFiles.physicalDirectory(root)
        guard try PortableProjectFiles.files(root) == [projectName, historyName] else { throw InspectionArchiveError.invalid }
        let project = try PortableProjectReader.prepare(at: root.appendingPathComponent(projectName))
        let (bytes, stamp) = try BoundReviewFiles.snapshot(root.appendingPathComponent(historyName), limit: PortableSettledBatchEvidence.maximumBytes)
        let history = try PortableSettledBatchEvidence.decode(bytes, project: project.project)
        let result = PortableSettledBatchAdmission(project: project, history: history, root: root, historyStamp: stamp)
        try validateCurrent(result)
        return result
    }
    private static func validateCurrent(_ value: PortableSettledBatchAdmission) throws {
        try PortableProjectFiles.physicalDirectory(value.root)
        guard try PortableProjectFiles.files(value.root) == [projectName, historyName],
              try ResumeFileIdentity.capture(value.root.appendingPathComponent(historyName)) == value.historyStamp else { throw InspectionArchiveError.invalid }
        try PortableProjectReader.validateCurrent(value.project)
    }
    public static func write(_ project: PortableProjectAdmission, history: PortableSettledBatchEvidence,
                             to target: URL) throws {
        // The evidence value cannot be forged publicly, but can belong to another project.
        _ = try PortableSettledBatchEvidence.decode(history.originalBytes, project: project.project)
        guard target.standardizedFileURL != project.packageURL.standardizedFileURL,
              !target.standardizedFileURL.path.hasPrefix(project.packageURL.standardizedFileURL.path + "/") else { throw InspectionArchiveError.invalid }
        let stage = try PortableProjectFiles.freshStage(for: target)
        defer { try? FileManager.default.removeItem(at: stage) }
        try Task.checkCancellation()
        try PortableProjectReader.writeAdmitted(project, to: stage.appendingPathComponent(projectName))
        try history.originalBytes.write(to: stage.appendingPathComponent(historyName), options: .withoutOverwriting)
        let admitted = try prepare(at: stage)
        guard admitted.project.projectBytes == project.projectBytes,
              admitted.project.manifestBytes == project.manifestBytes,
              admitted.history.originalBytes == history.originalBytes else { throw InspectionArchiveError.invalid }
        try Task.checkCancellation(); try PortableProjectReader.validateCurrent(project)
        try FileManager.default.moveItem(at: stage, to: target)
    }
    public static func reconstruct(_ admitted: PortableSettledBatchAdmission, to target: URL,
                                   beforePublish: @Sendable () throws -> Void = {}) async throws -> InspectionProjectStore {
        guard target.standardizedFileURL != admitted.root.standardizedFileURL,
              !target.standardizedFileURL.path.hasPrefix(admitted.root.standardizedFileURL.path + "/") else { throw InspectionArchiveError.invalid }
        try Task.checkCancellation(); try validateCurrent(admitted)
        let stage = try PortableProjectFiles.freshStage(for: target)
        defer { try? FileManager.default.removeItem(at: stage) }
        // Existing reconstruction requires an absent target. Its store is nested
        // within our owned stage, then history joins it before outer publication.
        let storeURL = stage.appendingPathComponent("store")
        _ = try await PortableProjectReader.reconstruct(admitted.project, to: storeURL)
        try admitted.history.originalBytes.write(to: storeURL.appendingPathComponent(historyName), options: .withoutOverwriting)
        try Task.checkCancellation(); try beforePublish(); try Task.checkCancellation()
        try validateCurrent(admitted)
        try FileManager.default.moveItem(at: storeURL, to: target)
        return InspectionProjectStore(root: target)
    }
    /// Detached read-only review, deliberately outside both live history stores.
    public static func history(in store: URL, project: InspectionProject) throws -> PortableSettledBatchEvidence {
        try PortableProjectFiles.physicalDirectory(store)
        let (bytes, _) = try BoundReviewFiles.snapshot(store.appendingPathComponent(historyName), limit: PortableSettledBatchEvidence.maximumBytes)
        return try PortableSettledBatchEvidence.decode(bytes, project: project)
    }
}
