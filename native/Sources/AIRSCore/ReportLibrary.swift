import Foundation

public struct LibraryProvenance: Codable, Sendable {
    public let sourceLabel: String
    public let inspectedInput: URL?
    public let symbolInput: URL?
    public let bundleImage: BundleImageProvenance?

    public init(sourceLabel: String, inspectedInput: URL? = nil, symbolInput: URL? = nil, bundleImage: BundleImageProvenance? = nil) {
        self.sourceLabel = sourceLabel
        self.inspectedInput = inspectedInput
        self.symbolInput = symbolInput
        self.bundleImage = bundleImage
    }
}

public struct RetainedReport: Sendable {
    public let data: Data
    public let report: AuditReport
    public let provenance: LibraryProvenance
}

public struct ReportLibraryEntry: Identifiable, Sendable {
    public let id: UUID
    public let savedAt: Date?
    public let sourceLabel: String
    public let image: ImageInfo?
    public let model: String?
    public let summary: ReportSummary?
    public let issue: String?
}

private struct AuditLibrarySummary: Sendable {
    let image: ImageInfo
    let model: String
    let summary: ReportSummary
}

/// Audit-facing adapter preserves the original API and version-1 on-disk format.
public struct ReportLibrary: Sendable {
    public static let maximumEntries = 128
    public static let maximumTotalBytes = 128 * 1_048_576
    private let store: SnapshotLibrary<AuditReport>

    public init(root: URL, maximumEntries: Int = Self.maximumEntries,
                maximumTotalBytes: Int = Self.maximumTotalBytes) {
        store = SnapshotLibrary(root: root, maximumReportBytes: ReportFiles.maximumBytes,
            maximumEntries: maximumEntries, maximumTotalBytes: maximumTotalBytes, decode: { try AuditReport.decode($0) })
    }
    public func entries() async throws -> [ReportLibraryEntry] {
        let entries = try await store.entries { report in
            AuditLibrarySummary(image: report.image, model: report.generator.analysisModelVersion, summary: report.summary)
        }
        return entries.map {
            ReportLibraryEntry(id: $0.id, savedAt: $0.savedAt, sourceLabel: $0.sourceLabel,
                image: $0.summary?.image, model: $0.summary?.model, summary: $0.summary?.summary, issue: $0.issue)
        }
    }
    /// Metadata-only membership; never substitutes for load's integrity checks.
    public func storedIDs() async throws -> Set<UUID> { try await store.storedIDs() }
    public func load(_ id: UUID) async throws -> RetainedReport {
        let retained = try await store.load(id)
        return RetainedReport(data: retained.data, report: retained.report, provenance: retained.provenance)
    }
    public func keep(_ data: Data, provenance: LibraryProvenance) async throws -> UUID {
        try await store.keep(data, provenance: provenance)
    }
    public func remove(_ id: UUID) async throws { try await store.remove(id) }
}
