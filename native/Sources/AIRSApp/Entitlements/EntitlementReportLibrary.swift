import Foundation
import AIRSCore
import EntitlementDiffCore

struct EntitlementLibrarySummary: Sendable {
    let previousName: String
    let currentName: String
    let architecture: String
    let previousKeys: Int
    let currentKeys: Int
}

typealias EntitlementLibraryEntry = SnapshotLibraryEntry<EntitlementLibrarySummary>

/// Entitlement snapshots use the audit library's immutable storage, in a separate root.
struct EntitlementReportLibrary: Sendable {
    private let store: SnapshotLibrary<SavedReport>
    let storageRoot: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIRS/EntitlementReportLibrary", isDirectory: true)
    }
    init(root: URL = Self.defaultRoot, maximumEntries: Int = 128, maximumTotalBytes: Int = 128 * 1_048_576) {
        storageRoot = root
        store = SnapshotLibrary(root: root, maximumReportBytes: SavedReport.maximumBytes,
            maximumEntries: maximumEntries, maximumTotalBytes: maximumTotalBytes, decode: { try SavedReport.parse($0) })
    }
    func keep(_ report: EntitlementDiffCore.ComparisonReport) async throws -> UUID {
        let bytes = try await Task.detached(priority: .userInitiated) { try report.jsonData() }.value
        return try await keep(bytes)
    }
    func keep(_ bytes: Data) async throws -> UUID {
        try await store.keep(bytes, provenance: LibraryProvenance(sourceLabel: "Entitlement comparison"))
    }
    func entries() async throws -> [EntitlementLibraryEntry] {
        try await store.entries { saved in
            EntitlementLibrarySummary(previousName: saved.previous.sourceName, currentName: saved.current.sourceName,
                architecture: saved.previous.architecture.rawValue,
                previousKeys: saved.previous.entitlements.entries.count, currentKeys: saved.current.entitlements.entries.count)
        }
    }
    func load(_ id: UUID) async throws -> RetainedSnapshot<SavedReport> { try await store.load(id) }
    func remove(_ id: UUID) async throws { try await store.remove(id) }
}
