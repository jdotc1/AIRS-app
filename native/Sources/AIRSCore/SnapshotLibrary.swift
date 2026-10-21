import CryptoKit
import Foundation

public struct RetainedSnapshot<Report: Sendable>: Sendable {
    public let data: Data
    public let report: Report
    public let provenance: LibraryProvenance
    public let reportURL: URL
}

public struct SnapshotLibraryEntry<Summary: Sendable>: Identifiable, Sendable {
    public let id: UUID
    public let savedAt: Date?
    public let sourceLabel: String
    public let summary: Summary?
    public let issue: String?
}

private struct LibraryReceipt: Codable {
    let version: Int
    let id: UUID
    let savedAt: Date
    let reportSHA256: String
    let provenance: LibraryProvenance
}

/// Raw reports are immutable snapshots. The index is derived, never a replacement
/// for report identity, configuration, unknown fields, or analysis evidence.
public actor SnapshotLibrary<Report: Sendable> {
    private let decode: @Sendable (Data) throws -> Report
    private let maximumReportBytes: Int
    private let root: URL
    private let maximumEntries: Int
    private let maximumTotalBytes: Int

    public init(root: URL, maximumReportBytes: Int, maximumEntries: Int = 128,
                maximumTotalBytes: Int = 128 * 1_048_576,
                decode: @escaping @Sendable (Data) throws -> Report) {
        self.decode = decode
        self.maximumReportBytes = maximumReportBytes
        self.root = root
        self.maximumEntries = maximumEntries
        self.maximumTotalBytes = maximumTotalBytes
    }

    public func entries<Summary: Sendable>(summarize: @Sendable (Report) -> Summary) throws -> [SnapshotLibraryEntry<Summary>] {
        let folders = try entryFolders()
        var remaining = maximumTotalBytes
        return folders.compactMap { folder -> SnapshotLibraryEntry<Summary>? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            do {
                let size = try rawSize(folder)
                guard size <= remaining else { throw invalid("Library byte limit exceeded; remove an entry before opening it.") }
                remaining -= size
                let (retained, receipt) = try read(id)
                return SnapshotLibraryEntry(id: id, savedAt: receipt.savedAt,
                    sourceLabel: retained.provenance.sourceLabel, summary: summarize(retained.report), issue: nil)
            } catch {
                return SnapshotLibraryEntry(id: id, savedAt: nil, sourceLabel: "Unavailable retained report",
                    summary: nil, issue: error.localizedDescription)
            }
        }.sorted {
            if $0.savedAt != $1.savedAt { return ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Directory membership only, for pruning derived references. This does not
    /// validate an entry or grant its contents authority as a report/cache hit.
    public func storedIDs() throws -> Set<UUID> {
        Set(try entryFolders().compactMap { UUID(uuidString: $0.lastPathComponent) })
    }

    public func load(_ id: UUID) throws -> RetainedSnapshot<Report> { try read(id).0 }

    public func keep(_ data: Data, provenance: LibraryProvenance, retainingID: UUID? = nil) throws -> UUID {
        guard data.count <= maximumReportBytes else { throw ReportError.tooLarge(maximumReportBytes) }
        _ = try decode(data)
        let folders = try entryFolders()
        var total = data.count
        for folder in folders {
            let size = try rawSize(folder)
            total += size
            // Equality is byte equality, not a filename, UUID, or symbol join.
            if size == data.count, let id = UUID(uuidString: folder.lastPathComponent),
               retainingID == nil || retainingID == id,
               let existing = try? read(id).0, existing.data == data,
               existing.provenance.sourceLabel == provenance.sourceLabel,
               existing.provenance.inspectedInput == provenance.inspectedInput,
               existing.provenance.symbolInput == provenance.symbolInput,
               existing.provenance.bundleImage == provenance.bundleImage { return id }
        }
        guard folders.count < maximumEntries, total <= maximumTotalBytes else {
            throw invalid("Report library is full (\(maximumEntries) reports / \(maximumTotalBytes) bytes). Remove a retained copy before keeping another.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = retainingID ?? UUID()
        guard !FileManager.default.fileExists(atPath: folder(id).path) else { throw invalid("Retained snapshot ID already exists.") }
        let stage = root.appendingPathComponent(".stage-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let receipt = LibraryReceipt(version: 1, id: id, savedAt: Date(),
            reportSHA256: digest(data), provenance: provenance)
        let receiptData = try JSONEncoder().encode(receipt)
        guard receiptData.count <= 16_384 else { throw invalid("Report provenance exceeds the library receipt limit.") }
        try data.write(to: stage.appendingPathComponent("report.json"), options: .atomic)
        try receiptData.write(to: stage.appendingPathComponent("receipt.json"), options: .atomic)
        // A single same-directory rename publishes both the raw report and receipt.
        try FileManager.default.moveItem(at: stage, to: folder(id))
        return id
    }

    /// Only the owned snapshot directory is removed; source images/reports are untouched.
    public func remove(_ id: UUID) throws {
        try requireDirectory(root)
        let target = folder(id)
        try requireDirectory(target)
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    private func read(_ id: UUID) throws -> (RetainedSnapshot<Report>, LibraryReceipt) {
        try requireDirectory(root)
        let target = folder(id)
        try requireDirectory(target)
        let receiptURL = target.appendingPathComponent("receipt.json")
        let reportURL = target.appendingPathComponent("report.json")
        try rejectSymlink(receiptURL)
        try rejectSymlink(reportURL)
        let receipt = try JSONDecoder().decode(LibraryReceipt.self,
            from: ReportFiles.readBounded(receiptURL, limit: 16_384))
        guard receipt.version == 1, receipt.id == id else { throw invalid("Invalid library receipt.") }
        let data = try ReportFiles.readBounded(reportURL, limit: min(maximumReportBytes, maximumTotalBytes))
        guard digest(data) == receipt.reportSHA256 else {
            throw invalid("Retained report bytes changed. Reimport the original report instead of trusting this copy.")
        }
        return (RetainedSnapshot<Report>(data: data, report: try decode(data), provenance: receipt.provenance, reportURL: reportURL), receipt)
    }

    private func entryFolders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try requireDirectory(root)
        let folders = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard folders.count <= maximumEntries else { throw invalid("Library entry limit exceeded.") }
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func rawSize(_ folder: URL) throws -> Int {
        try requireDirectory(folder)
        let url = folder.appendingPathComponent("report.json")
        try rejectSymlink(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= maximumReportBytes else { throw invalid("Retained report is missing, invalid, or too large.") }
        return size
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func rejectSymlink(_ url: URL) throws {
        var current = url
        current.removeAllCachedResourceValues()
        if try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw invalid("Library entries cannot be symbolic links.")
        }
    }
    private func requireDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        var current = url
        current.removeAllCachedResourceValues()
        guard try current.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw invalid("Library location is not a directory.")
        }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func invalid(_ message: String) -> ReportError { .invalidContents(message) }
}
