import CryptoKit
import Foundation

public struct AnalysisReuseHit: Sendable {
    public let retainedID: UUID
    public let data: Data
    public let generatedAt: Date
}

/// Adapted from MacScope NativeDecompilerProcessRuntime's RequestKey/CacheKey,
/// validated-success admission and bounded cache. AIRS persists a library reference;
/// no XPC/runtime handle or mutable report is cached. Only owned default audits enroll.
public actor AnalysisReuse {
    private struct VersionEnvelope: Decodable { let version: Int }
    private struct Receipt: Codable {
        let version: Int
        let retainedID: UUID
        let generatedAt: Date
        let input: BatchInputIdentity
        let context: String
        let image: ImageInfo
        let analysisConfig: Data
    }
    public struct Ticket: Sendable {
        fileprivate let input: BatchInputIdentity
        fileprivate let context: String
    }
    private let root: URL
    private let library: ReportLibrary
    private let maximumEntries: Int
    private var isEnrolling = false
    public init(root: URL, library: ReportLibrary, maximumEntries: Int = 128) {
        self.root = root; self.library = library; self.maximumEntries = min(128, max(0, maximumEntries))
    }

    /// Metadata is only a change detector around an owned generation, never a
    /// substitute for the engine's exact container/slice digest. No image rehash.
    public func ticket(input: URL, configuration: EngineConfiguration) throws -> Ticket? {
        // Bound first slice to the immutable private runtime. External Python,
        // arbitrary directories and symbol-enriched reports are never eligible.
        guard configuration.isBundled else { return nil }
        let identity = try BatchInputIdentity.capture(input)
        let framework = configuration.pythonExecutable.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard framework.lastPathComponent == "Python.framework" else { return nil }
        let engine = configuration.bootstrap.deletingLastPathComponent()
        let expectedEngine = framework.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Engine").standardizedFileURL
        guard engine.standardizedFileURL == expectedEngine,
              configuration.bootstrap.lastPathComponent == "airs_cli.py" else { return nil }
        var links: [String] = []
        var records: [ResumeFileIdentity] = []
        for folder in [framework, engine] {
            guard let iterator = FileManager.default.enumerator(at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return nil }
            var count = 0
            for case let file as URL in iterator {
                count += 1
                guard count <= 8192 else { return nil }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    guard file.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/") else { return nil }
                    links.append(file.path + "=" + (try FileManager.default.destinationOfSymbolicLink(atPath: file.path)))
                    continue
                }
                if values.isRegularFile == true { records.append(try ResumeFileIdentity.capture(file)) }
            }
        }
        records.sort { $0.path < $1.path }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Hash only the new canonical metadata request, not source/runtime bytes.
        let metadata = try encoder.encode(records) + encoder.encode(links.sorted())
        let context = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
            + "/owned-audit-auto-default-v1/-I-B-S"
        return Ticket(input: identity, context: context)
    }

    public func lookup(_ ticket: Ticket, input: URL, configuration: EngineConfiguration) async throws -> AnalysisReuseHit? {
        let folders = try receiptInventory().files
        for file in folders {
            try Task.checkCancellation()
            guard let receipt = try? JSONDecoder().decode(Receipt.self,
                from: ReportFiles.readBounded(file, limit: 32_768)), receipt.version == 1,
                receipt.input == ticket.input, receipt.context == ticket.context else { continue }
            guard let retained = try? await library.load(receipt.retainedID),
                retained.provenance.symbolInput == nil,
                try sameImage(retained.report.image, receipt.image),
                try config(retained.data) == receipt.analysisConfig,
                retained.report.generator.analysisModelVersion == "arm64-bounded-sequential-loops-v31",
                let current = try self.ticket(input: input, configuration: configuration),
                current.input == ticket.input, current.context == ticket.context else { continue }
            try Task.checkCancellation()
            return AnalysisReuseHit(retainedID: receipt.retainedID, data: retained.data, generatedAt: receipt.generatedAt)
        }
        return nil
    }

    /// Admission is called only after an actual owned audit, not on import/Keep.
    /// Failure to enroll must never discard the completed report.
    public func enroll(_ data: Data, input: URL, configuration: EngineConfiguration, before: Ticket,
                       provenance: LibraryProvenance) async throws -> UUID? {
        // Keep admission/maintenance serialized across the library actor hop.
        // A concurrent caller keeps its completed result but declines cache admission.
        guard maximumEntries > 0, !isEnrolling else { return nil }
        isEnrolling = true
        defer { isEnrolling = false }
        guard let after = try ticket(input: input, configuration: configuration),
              after.input == before.input, after.context == before.context,
              provenance.symbolInput == nil else { return nil }
        let report = try AuditReport.decode(data)
        guard report.generator.analysisModelVersion == "arm64-bounded-sequential-loops-v31",
              report.image.architecture == "arm64",
              report.image.sliceSHA256.count == 64, report.image.containerSHA256.count == 64,
              report.sourceAnnotations == nil else { return nil }
        let analysisConfig = try config(data)
        let inventory = try receiptInventory(allowOverflow: true)
        let files = inventory.files
        let existing = try files.map { file in
            let bytes = try ReportFiles.readBounded(file, limit: 32_768)
            return (file, try? JSONDecoder().decode(Receipt.self, from: bytes),
                try? JSONDecoder().decode(VersionEnvelope.self, from: bytes).version)
        }
        // A future receipt format belongs to its writer. Reserve its slot rather
        // than deleting it or using it as evidence.
        let reserved = existing.filter { $0.2 != nil && $0.2 != 1 }.count
        guard reserved < maximumEntries else { return nil }
        let id = try await library.keep(data, provenance: provenance)
        let receipt = Receipt(version: 1, retainedID: id, generatedAt: Date(), input: before.input,
            context: before.context, image: report.image, analysisConfig: analysisConfig)
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 32_768 else { return nil }
        // Membership is metadata only: maintenance never opens, decodes or hashes
        // retained reports. Lookup retains its separate full evidence checks.
        let retainedIDs = try await library.storedIDs()
        var candidates: [(URL, Receipt)] = []
        var removals: [URL] = []
        for (file, old, version) in existing {
            if let version, version != 1 { continue }
            guard let old else { removals.append(file); continue }
            if !retainedIDs.contains(old.retainedID)
                || (old.input == before.input && old.context == before.context) {
                removals.append(file)
            } else { candidates.append((file, old)) }
        }
        // Adapt MacScope's bounded replacement/trim policy. Enrollment time is
        // persisted; lookup does not touch disk merely to update cache recency.
        candidates.sort {
            if $0.1.generatedAt != $1.1.generatedAt { return $0.1.generatedAt < $1.1.generatedAt }
            return $0.0.lastPathComponent < $1.0.lastPathComponent
        }
        removals += candidates.prefix(max(0, candidates.count + reserved + 1 - maximumEntries)).map { $0.0 }
        // The scan cap also includes ignored children. Do not create a cache
        // that its next lookup cannot enumerate, or delete ignored entries.
        guard inventory.directoryCount - removals.count + 1 <= 512 else { return nil }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Only derived receipts are evicted. Reports, source inputs and batch IDs
        // remain intact, including if the final receipt write fails.
        for file in removals { try FileManager.default.removeItem(at: file) }
        try bytes.write(to: root.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        return id
    }

    private func config(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configuration = object["analysis_config"] as? [String: Any], !configuration.isEmpty else {
            throw ReportError.invalidContents("Report has no reusable analysis configuration.")
        }
        return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    }
    private func sameImage(_ a: ImageInfo, _ b: ImageInfo) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(a) == encoder.encode(b)
    }
    private func receiptInventory(allowOverflow: Bool = false) throws -> (files: [URL], directoryCount: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ReportError.invalidContents("Reuse receipt directory cannot be a link.")
        }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard files.count <= 512 else { throw ReportError.invalidContents("Reuse directory scan limit exceeded.") }
        let receipts = try files.filter { file in
            guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { return false }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            return values.isSymbolicLink != true && values.isRegularFile == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard allowOverflow || receipts.count <= maximumEntries else {
            throw ReportError.invalidContents("Reuse receipt limit exceeded.")
        }
        return (receipts, files.count)
    }
}
