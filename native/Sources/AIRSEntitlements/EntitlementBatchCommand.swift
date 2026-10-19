import Foundation
import EntitlementDiffCore

/// CLI orchestration only. The manifest and runner retain selection/execution semantics.
public struct EntitlementBatchCommand: Sendable {
    public static let usage = """
    Usage: airs-entitlements batch --manifest <plan.json> --output-directory <new-directory>
    Execute the manifest's ordered pairs and explicit architectures. No target execution.
    Version 2 paths resolve from the manifest folder; version 1 paths are absolute.
    Writes schema-1 reports and summary.json; also writes the summary to stdout.
    Existing destinations are refused. The parent directory must exist.
    Exit: 0 all unique pairs equal; 1 differences; 2 any failed, unsaved or incomplete pair/output.
    Duplicates are skipped. Partial results remain on disk. No GUI history or resume state.
    Declarations are not effective permissions or a trust verdict. Messages may include paths.
    """
    public let manifestURL: URL
    public let outputDirectory: URL

    public init(arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--manifest", "--output-directory"].contains(key), values[key] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].utf8.contains(0) else {
                throw EntitlementBatchCommandError.arguments
            }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let manifest = values["--manifest"], let output = values["--output-directory"] else {
            throw EntitlementBatchCommandError.arguments
        }
        func url(_ path: String, isDirectory: Bool) -> URL {
            URL(fileURLWithPath: path.hasPrefix("/") ? path : directory.path + "/" + path,
                isDirectory: isDirectory).standardizedFileURL
        }
        manifestURL = url(manifest, isDirectory: false)
        outputDirectory = url(output, isDirectory: true)
    }

    public struct Summary: Encodable, Sendable {
        public let kind = "airs-entitlement-batch-result"
        public let version = 1
        public let settled: Bool
        public let cancelled: Bool
        public let exitStatus: Int32
        public let rows: [Row]
        public struct Row: Encodable, Sendable {
            /// One-based index in the original manifest, including skipped duplicates.
            public let index: Int
            public let architecture: Architecture
            public let status: EntitlementBatchStatus
            public let message: String
            public let changedCount: Int?
            public let unchangedCount: Int?
            public let reportFile: String?
            /// Includes absent versus present-empty representation differences.
            public let differences: Bool?
        }
    }
    public struct Result: Sendable {
        public let summary: Summary
        public var exitStatus: Int32 { summary.exitStatus }
        public let standardOutput: Data
    }

    public func run(reader: any SnapshotReading) async throws -> Result {
        try await execute(reader: reader, writeReport: { data, url in
            try data.write(to: url, options: .withoutOverwriting)
        })
    }

    // Internal seam exercises publication failures without modifying the shared runner.
    func execute(reader: any SnapshotReading,
                 writeReport: @escaping @Sendable (Data, URL) throws -> Void) async throws -> Result {
        let pairs = try EntitlementBatchManifest.read(manifestURL).makePairs()
        let inputs = [manifestURL] + pairs.flatMap { [$0.previous, $0.current] }
        try ReportDestination.validate(outputDirectory, excluding: inputs)
        try Task.checkCancellation()
        // Reuse the immutable-store staging/move pattern: move refuses any existing
        // destination, including empty directories and symlinks. No overwrite/delete.
        let manager = FileManager.default
        let stage = outputDirectory.deletingLastPathComponent()
            .appendingPathComponent(".airs-batch-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        try manager.moveItem(at: stage, to: outputDirectory)

        let output = BatchCommandOutput(root: outputDirectory, inputs: inputs, write: writeReport)
        let batch = try await EntitlementBatchRunner().run(pairs: pairs, reader: reader,
            retain: { try await output.keep($0) })
        let exports = await output.exports
        let rows: [Summary.Row] = batch.rows.enumerated().map { index, row in
            let exported = row.retainedReportID.flatMap { exports[$0] }
            let message: String
            if row.status == .completed {
                message = exported == nil ? "Comparison completed but export failed. Complete bytes were not retained by this command; later pairs were not started." : "Complete comparison exported."
            } else { message = row.message }
            return .init(index: index + 1, architecture: row.pair.architecture, status: row.status,
                message: message, changedCount: row.changedCount, unchangedCount: row.unchangedCount,
                reportFile: exported?.file, differences: exported?.differences)
        }
        let incomplete = !batch.settled || batch.cancelled || batch.hasUnretainedReport || rows.contains {
            $0.status != .duplicate && ($0.status != .completed || $0.reportFile == nil)
        }
        let status: Int32 = incomplete ? 2 : (rows.contains { $0.differences == true } ? 1 : 0)
        let summary = Summary(settled: batch.settled, cancelled: batch.cancelled, exitStatus: status, rows: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(summary); data.append(10)
        let summaryURL = outputDirectory.appendingPathComponent("summary.json")
        try ReportDestination.validate(summaryURL, excluding: inputs)
        try data.write(to: summaryURL, options: .withoutOverwriting)
        return Result(summary: summary, standardOutput: data)
    }
}

public enum EntitlementBatchCommandError: Error, LocalizedError, Sendable {
    case arguments
    public var errorDescription: String? {
        "Invalid batch arguments. Use batch --help; --manifest and --output-directory are required."
    }
}

private actor BatchCommandOutput {
    struct Export: Sendable { let file: String; let differences: Bool }
    private let root: URL
    private let inputs: [URL]
    private let write: @Sendable (Data, URL) throws -> Void
    private(set) var exports: [UUID: Export] = [:]
    init(root: URL, inputs: [URL], write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.root = root; self.inputs = inputs; self.write = write
    }
    func keep(_ data: Data) throws -> UUID {
        let report = try SavedReport.parse(data)
        let differences = report.previous.presence != report.current.presence ||
            report.previous.entitlements != report.current.entitlements
        let id = UUID()
        let file = "\(id.uuidString).json"
        let destination = root.appendingPathComponent(file)
        try ReportDestination.validate(destination, excluding: inputs)
        try write(data, destination)
        exports[id] = Export(file: file, differences: differences)
        return id
    }
}
