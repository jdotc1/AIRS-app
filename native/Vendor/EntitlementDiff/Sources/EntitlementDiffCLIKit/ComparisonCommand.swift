import Foundation
import EntitlementDiffCore

public struct ComparisonCommand: Sendable {
    public static let usage = """
    Usage: entitlementdiff-cli --previous <app> --current <app> --architecture <arm64|x86_64> [--output <new-file>]
    JSON goes to stdout unless --output names a new file. Existing files are never overwritten.
    Exit: 0 equal declarations; 1 differences; 2 input/inspection/output failure; --help exits 0.
    Requested architecture of the main executable only; no target execution or fallback slice.
    Declarations are not effective permissions or a trust verdict. Schema-1 reports omit source paths.
    """
    public let previous: URL
    public let current: URL
    public let architecture: Architecture
    public let output: URL?

    public init(arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        var values: [String: String] = [:]
        let allowed = ["--previous", "--current", "--architecture", "--output"]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), values[key] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--"),
                  !arguments[index + 1].utf8.contains(0) else { throw CommandError.invalidArguments }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let before = values["--previous"], let after = values["--current"],
              let arch = values["--architecture"].flatMap(Architecture.init(rawValue:)) else { throw CommandError.invalidArguments }
        func path(_ text: String) -> URL {
            URL(fileURLWithPath: text.hasPrefix("/") ? text : directory.path + "/" + text).standardizedFileURL
        }
        previous = path(before); current = path(after); architecture = arch
        output = values["--output"].map(path)
    }

    public struct Result: Sendable {
        public let exitStatus: Int32
        public let standardOutput: Data
    }

    public func run(reader: any SnapshotReading) async throws -> Result {
        // Check destination before extraction and again immediately before publication.
        if let output { try ReportDestination.validate(output, excluding: [previous, current]) }
        let before = try await reader.read(at: previous, architecture: architecture)
        let after = try await reader.read(at: current, architecture: architecture)
        guard before.architecture == architecture, after.architecture == architecture else { throw CommandError.wrongArchitecture }
        let report = try ComparisonReport(previous: before, current: after)
        let data = try report.jsonData()
        let status: Int32 = report.changes.isEmpty && before.presence == after.presence ? 0 : 1
        if let output {
            try ReportDestination.validate(output, excluding: [previous, current])
            // Exclusive creation refuses existing files, symlinks and input aliases.
            // A filesystem write failure can leave partial output; no success is reported.
            try data.write(to: output, options: .withoutOverwriting)
            return Result(exitStatus: status, standardOutput: Data())
        }
        return Result(exitStatus: status, standardOutput: data)
    }
}

public enum CommandError: Error, LocalizedError {
    case invalidArguments, wrongArchitecture
    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid arguments. Use --help for required options."
        case .wrongArchitecture: "Inspection did not return the requested architecture. No fallback is permitted."
        }
    }
}
