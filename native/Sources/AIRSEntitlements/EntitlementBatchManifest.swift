import Foundation
import AIRSCore
import EntitlementDiffCore

public enum EntitlementBatchManifestError: Error, LocalizedError, Sendable {
    case invalid, limit, path, base
    public var errorDescription: String? {
        switch self {
        case .invalid: "Not a valid entitlement batch manifest. Expected kind, version (1 or 2) and 1–16 pairs of previousPath, currentPath and architecture."
        case .limit: "Batch manifest exceeds its limits (256 KiB, 16 pairs or 4,096 UTF-8 bytes per path)."
        case .path: "Manifest inputs must be .app paths without NUL, empty, dot or parent components. Version 1 requires absolute local paths; version 2 requires relative paths without URLs or shell expansion."
        case .base: "Relative manifests require a local manifest folder containing every selected app path. Save the manifest beside or above all selected app folders."
        }
    }
}

/// Selection exchange only. No row/execution identity, outcomes or resume authority.
/// Version 2 resolves paths lexically against the manifest's folder, never cwd.
public struct EntitlementBatchManifest: Encodable, Sendable {
    public static let kind = "airs-entitlement-batch-manifest"
    public static let maximumBytes = 256 * 1_024
    public static let maximumPathBytes = 4_096

    public struct Selection: Encodable, Sendable {
        public let previousPath: String
        public let currentPath: String
        public let architecture: Architecture

        fileprivate init(previousPath: String, currentPath: String, architecture: Architecture, relative: Bool = false) throws {
            try EntitlementBatchManifest.validate(path: previousPath, relative: relative)
            try EntitlementBatchManifest.validate(path: currentPath, relative: relative)
            self.previousPath = previousPath; self.currentPath = currentPath; self.architecture = architecture
        }
        fileprivate func makePair() -> EntitlementBatchPair {
            .init(previous: URL(fileURLWithPath: previousPath, isDirectory: true), current: URL(fileURLWithPath: currentPath, isDirectory: true), architecture: architecture)
        }
    }

    public let version: Int
    public let kind = Self.kind
    public let pairs: [Selection]
    private let absoluteSelections: [Selection]
    private let baseDirectory: URL?
    private enum CodingKeys: String, CodingKey { case kind, version, pairs }

    /// Omit relativeTo for the unchanged version-1 absolute-path format.
    public init(pairs: [EntitlementBatchPair], relativeTo directory: URL? = nil) throws {
        guard !pairs.isEmpty, pairs.count <= EntitlementBatchRunner.maximumPairs else { throw EntitlementBatchManifestError.limit }
        let absolute = try pairs.map { pair in
            for url in [pair.previous, pair.current] { try Self.local(url) }
            return try Selection(previousPath: pair.previous.path, currentPath: pair.current.path, architecture: pair.architecture)
        }
        absoluteSelections = absolute
        if let directory {
            let base = try Self.base(directory)
            baseDirectory = base; version = 2
            self.pairs = try absolute.map {
                try Selection(previousPath: Self.relative($0.previousPath, to: base),
                    currentPath: Self.relative($0.currentPath, to: base), architecture: $0.architecture, relative: true)
            }
        } else {
            baseDirectory = nil; version = 1; self.pairs = absolute
        }
    }

    private init(version: Int, selections: [Selection], absolute: [Selection], base: URL?) {
        self.version = version; pairs = selections; absoluteSelections = absolute; baseDirectory = base
    }

    /// Allocate session-local identities once when staging an import, never in view body.
    public func makePairs() -> [EntitlementBatchPair] { absoluteSelections.map { $0.makePair() } }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw EntitlementBatchManifestError.limit }
        return data
    }

    public static func read(_ url: URL) throws -> Self {
        try local(url)
        return try parse(ReportFiles.readBounded(url, limit: maximumBytes), relativeTo: url.deletingLastPathComponent())
    }

    /// A version-2 byte stream needs an explicit base supplied by its host.
    /// App paths are not opened, tested for existence or resolved through symlinks.
    public static func parse(_ data: Data, relativeTo directory: URL? = nil) throws -> Self {
        guard data.count <= maximumBytes else { throw EntitlementBatchManifestError.limit }
        var parser = ManifestParser(data)
        let parsed = try parser.parse()
        let relative = parsed.version == 2
        let base: URL?
        if relative {
            guard let directory else { throw EntitlementBatchManifestError.base }
            base = try Self.base(directory)
        } else { base = nil }
        let selections = try parsed.pairs.map {
            try Selection(previousPath: $0.0, currentPath: $0.1, architecture: $0.2, relative: relative)
        }
        let absolute: [Selection]
        if let base {
            absolute = try selections.map {
                try Selection(previousPath: base.appendingPathComponent($0.previousPath, isDirectory: true).path,
                    currentPath: base.appendingPathComponent($0.currentPath, isDirectory: true).path, architecture: $0.architecture)
            }
        } else { absolute = selections }
        return Self(version: parsed.version, selections: selections, absolute: absolute, base: base)
    }

    private static func local(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { throw EntitlementBatchManifestError.path }
    }
    private static func base(_ directory: URL) throws -> URL {
        try local(directory)
        return directory.standardizedFileURL
    }
    private static func relative(_ path: String, to base: URL) throws -> String {
        let prefix = base.path == "/" ? "/" : base.path + "/"
        // File names use exact UTF-8 bytes, not canonical-equivalence comparisons.
        guard path.utf8.starts(with: prefix.utf8) else { throw EntitlementBatchManifestError.base }
        return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    }
    private static func validate(path: String, relative: Bool = false) throws {
        guard path.utf8.count <= maximumPathBytes else { throw EntitlementBatchManifestError.limit }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let components = relative ? parts[...] : parts.dropFirst()
        guard !path.isEmpty, path.hasPrefix("/") != relative, !path.utf8.contains(0),
              !relative || (!path.hasPrefix("~") && !path.contains(":")),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path, isDirectory: true).pathExtension.lowercased() == "app" else { throw EntitlementBatchManifestError.path }
    }

    /// Atomic plan export reuses the donor's input/alias-aware destination protection.
    public func write(to url: URL, excluding inputs: [URL]) throws {
        if let baseDirectory {
            let destinationBase = try Self.base(url.deletingLastPathComponent())
            guard baseDirectory.path.utf8.elementsEqual(destinationBase.path.utf8) else { throw EntitlementBatchManifestError.base }
        }
        let bytes = try data()
        let selected = makePairs().flatMap { [$0.previous, $0.current] }
        try ReportDestination.validate(url, excluding: inputs + selected)
        try bytes.write(to: url, options: .atomic)
    }
}

/// Fixed-depth JSON grammar: root object, pair array, pair objects, scalar strings.
/// Foundation only sees bounded scalar tokens, not arbitrary containers.
private struct ManifestParser {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ data: Data) { bytes = Array(data) }

    private mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }
    private mutating func require(_ byte: UInt8) throws {
        guard take(byte) else { throw EntitlementBatchManifestError.invalid }
    }
    private mutating func string() throws -> String {
        whitespace(); let start = offset
        try require(34)
        // A 4,096-byte string can use six-byte Unicode escapes for every ASCII byte.
        while offset < bytes.count && offset - start <= EntitlementBatchManifest.maximumPathBytes * 6 + 2 {
            let byte = bytes[offset]; offset += 1
            if byte == 92 {
                guard offset < bytes.count else { throw EntitlementBatchManifestError.invalid }
                offset += 1
            } else if byte == 34 {
                let value: String
                do { value = try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw EntitlementBatchManifestError.invalid }
                guard value.utf8.count <= EntitlementBatchManifest.maximumPathBytes else { throw EntitlementBatchManifestError.limit }
                return value
            }
        }
        throw EntitlementBatchManifestError.limit
    }

    mutating func parse() throws -> (version: Int, pairs: [(String, String, Architecture)]) {
        try require(123)
        var seen = Set<String>()
        var selections: [(String, String, Architecture)]?
        var version: Int?
        repeat {
            let key = try string()
            guard seen.insert(key).inserted else { throw EntitlementBatchManifestError.invalid }
            try require(58)
            switch key {
            case "kind": guard try string() == EntitlementBatchManifest.kind else { throw EntitlementBatchManifestError.invalid }
            case "version":
                if take(49) { version = 1 }
                else if take(50) { version = 2 }
                else { throw EntitlementBatchManifestError.invalid }
            case "pairs": selections = try pairs()
            default: throw EntitlementBatchManifestError.invalid
            }
            if take(125) { break }
            try require(44)
        } while true
        whitespace()
        guard offset == bytes.count, seen == ["kind", "version", "pairs"], let selections, let version else { throw EntitlementBatchManifestError.invalid }
        return (version, selections)
    }

    private mutating func pairs() throws -> [(String, String, Architecture)] {
        try require(91)
        var selections: [(String, String, Architecture)] = []
        repeat {
            guard selections.count < EntitlementBatchRunner.maximumPairs else { throw EntitlementBatchManifestError.limit }
            try require(123)
            var fields: [String: String] = [:]
            repeat {
                let key = try string()
                guard ["previousPath", "currentPath", "architecture"].contains(key), fields[key] == nil else { throw EntitlementBatchManifestError.invalid }
                try require(58); fields[key] = try string()
                if take(125) { break }
                try require(44)
            } while true
            guard let previous = fields["previousPath"], let current = fields["currentPath"],
                  let raw = fields["architecture"], let architecture = Architecture(rawValue: raw) else { throw EntitlementBatchManifestError.invalid }
            selections.append((previous, current, architecture))
            if take(93) { return selections }
            try require(44)
        } while true
    }
}
