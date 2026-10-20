import Foundation
import AIRSCore

public struct InspectionLibrarySummary: Sendable {
    public let identity: InspectionIdentity?
    public let sourceName: String
    public let signingIdentifier: String
    public let architecture: String
    public let capturedAt: Date
    public let producerVersion: String
    public let entitlementCount: Int

    public func matches(_ query: String, label: String) -> Bool {
        query.isEmpty || [label, sourceName, identity?.bundleIdentifier, identity?.version, identity?.build, architecture]
            .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
    }
}

public typealias InspectionLibraryEntry = SnapshotLibraryEntry<InspectionLibrarySummary>

/// Retains complete inspection documents separately from legacy comparison reports.
/// Receipt digests protect document bytes; they are not executable hashes.
public struct InspectionLibrary: Sendable {
    public static let maximumEntries = 128
    public static let maximumTotalBytes = 128 * 1_048_576
    public let storageRoot: URL
    private let store: SnapshotLibrary<InspectionDocument>

    public init(root: URL, maximumEntries: Int = Self.maximumEntries,
                maximumTotalBytes: Int = Self.maximumTotalBytes) {
        storageRoot = root
        store = SnapshotLibrary(root: root,
            maximumReportBytes: InspectionDocumentCodec.maximumBytes,
            maximumEntries: maximumEntries, maximumTotalBytes: maximumTotalBytes,
            decode: { try InspectionDocumentCodec.decode($0) })
    }

    public func keep(_ document: InspectionDocument, label: String) async throws -> UUID {
        let data = try await Task.detached(priority: .userInitiated) {
            try InspectionDocumentCodec.encode(document)
        }.value
        return try await keep(data, label: label)
    }

    public func keep(_ data: Data, label: String) async throws -> UUID {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReportError.invalidContents("Use a nonempty baseline name of at most 256 UTF-8 bytes, without control characters.")
        }
        // SnapshotLibrary validates the document, checks capacity, stages bytes plus
        // receipt, and publishes with one rename. Never persist selected app URLs.
        return try await store.keep(data, provenance: LibraryProvenance(sourceLabel: name))
    }

    public func entries() async throws -> [InspectionLibraryEntry] {
        try await store.entries { document in
            InspectionLibrarySummary(identity: document.identity, sourceName: document.snapshot.sourceName,
                signingIdentifier: document.snapshot.signingIdentifier,
                architecture: document.snapshot.architecture.rawValue,
                capturedAt: document.capturedAt, producerVersion: document.producerVersion,
                entitlementCount: document.snapshot.entitlements.entries.count)
        }
    }

    public func load(_ id: UUID) async throws -> RetainedSnapshot<InspectionDocument> {
        try await store.load(id)
    }

    public func remove(_ id: UUID) async throws { try await store.remove(id) }
}
