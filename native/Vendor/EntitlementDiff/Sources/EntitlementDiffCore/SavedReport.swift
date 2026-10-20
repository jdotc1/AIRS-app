import Foundation

public enum SavedReportError: Error, LocalizedError, Sendable {
    case invalid, limit
    public var errorDescription: String? {
        switch self {
        case .invalid: "Not a supported, valid EntitlementDiff schema-1 report."
        case .limit: "Saved report exceeds import limits (8 MiB, 96 JSON levels, 100,000 nodes or 1 MiB per string)."
        }
    }
}

/// Bounded schema-1 ingestion. Derived claims are validated structurally but recomputed.
public struct SavedReport: Sendable, Identifiable {
    public let id = UUID()
    public let previous: EntitlementSnapshot
    public let current: EntitlementSnapshot
    public static let maximumBytes = 8 * 1_024 * 1_024

    public static func read(at url: URL) throws -> Self {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw SavedReportError.invalid }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw SavedReportError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SavedReportError.limit }
        var parser = BoundedJSON(data)
        let root = try parser.parse()
        let fields = try root.object(["schemaVersion", "tool", "scope", "signatureValidation", "gatekeeperAssessment", "previous", "current", "changes", "unchangedCount", "notices"])
        guard fields["schemaVersion"] == .number("1"), try fields.string("tool") == "EntitlementDiff",
              try fields.string("signatureValidation") == "notPerformed", try fields.string("gatekeeperAssessment") == "notPerformed" else { throw SavedReportError.invalid }
        _ = try fields.string("scope")
        guard case .number(let count) = fields["unchangedCount"], let total = UInt64(count), total <= 100_000 else { throw SavedReportError.invalid }
        for notice in try fields.array("notices") { _ = try notice.string() }
        for change in try fields.array("changes") {
            guard case .object(let c) = change, let kind = c["kind"] else { throw SavedReportError.invalid }
            let label = try kind.string()
            let keys: Set<String>
            switch label {
            case "added": keys = ["key", "kind", "current"]
            case "removed": keys = ["key", "kind", "previous"]
            case "changed": keys = ["key", "kind", "previous", "current"]
            default: throw SavedReportError.invalid
            }
            _ = try change.object(keys); _ = try c.string("key")
            if let old = c["previous"] { _ = try SnapshotJSONDecoder.value(old) }
            if let new = c["current"] { _ = try SnapshotJSONDecoder.value(new) }
        }
        let old = try SnapshotJSONDecoder.snapshot(fields.required("previous"))
        let new = try SnapshotJSONDecoder.snapshot(fields.required("current"))
        _ = try ComparisonReport(previous: old, current: new)
        return Self(previous: old, current: new)
    }
}

/// Standalone snapshots reuse schema-1's exact typed decoder and import budgets.
/// This is not a comparison report. Decoded snapshots are saved, unverified metadata.
public enum EntitlementSnapshotJSONCodec {
    public static let maximumBytes = SavedReport.maximumBytes

    public static func decode(_ data: Data) throws -> EntitlementSnapshot {
        try SnapshotJSONDecoder.snapshot(root(data))
    }

    public static func encode(_ snapshot: EntitlementSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        _ = try decode(data)
        return data
    }

    /// Validates every JSON token, duplicate object key and global budget before
    /// selecting a snapshot. The caller must also decode and validate its metadata.
    /// The exact outer key set and integer schemaVersion token are mandatory.
    public static func decodeEnvelope(_ data: Data, snapshotKey: String,
                                      expectedKeys: Set<String>, schemaVersion: Int = 1) throws -> EntitlementSnapshot {
        let fields = try root(data).object(expectedKeys)
        guard expectedKeys.contains(snapshotKey), expectedKeys.contains("schemaVersion"),
              fields["schemaVersion"] == .number(String(schemaVersion)) else { throw SavedReportError.invalid }
        return try SnapshotJSONDecoder.snapshot(fields.required(snapshotKey))
    }

    private static func root(_ data: Data) throws -> JSONNode {
        guard data.count <= maximumBytes else { throw SavedReportError.limit }
        var parser = BoundedJSON(data)
        return try parser.parse()
    }
}

private enum SnapshotJSONDecoder {
    static func snapshot(_ node: JSONNode) throws -> EntitlementSnapshot {
        let f = try node.object(["sourceName", "signingIdentifier", "architecture", "presence", "origin", "entitlements"])
        let name = try f.string("sourceName"), signing = try f.string("signingIdentifier")
        guard !name.isEmpty, name.utf8.count <= 1_024, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !signing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, signing.utf8.count <= 4_096,
              let architecture = Architecture(rawValue: try f.string("architecture")),
              let presence = EntitlementPresence(rawValue: try f.string("presence")),
              let origin = SnapshotOrigin(rawValue: try f.string("origin")) else { throw SavedReportError.invalid }
        let entries = try dictionary(f.required("entitlements"))
        guard presence != .notPresent || entries.entries.isEmpty else { throw SavedReportError.invalid }
        return .init(sourceName: name, signingIdentifier: signing, architecture: architecture,
                     presence: presence, origin: origin, entitlements: entries, isSavedBaseline: true)
    }

    static func dictionary(_ node: JSONNode) throws -> EntitlementDictionary {
        guard case .array(let entries) = node else { throw SavedReportError.invalid }
        return try EntitlementDictionary(entries: entries.map { entry in
            let f = try entry.object(["key", "value"])
            return .init(key: try f.string("key"), value: try value(f.required("value")))
        })
    }
    static func value(_ node: JSONNode) throws -> EntitlementValue {
        let f = try node.object(["type", "value"]), raw = try f.required("value")
        switch try f.string("type") {
        case "boolean": guard case .boolean(let v) = raw else { throw SavedReportError.invalid }; return .boolean(v)
        case "integer":
            let s = try raw.string()
            guard s.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil else { throw SavedReportError.invalid }
            if let v = Int64(s) { return .integer(v) }
            guard let v = UInt64(s) else { throw SavedReportError.invalid }; return .unsignedInteger(v)
        case "real", "date-reference-seconds":
            guard case .number(let s) = raw, let v = Double(s), v.isFinite else { throw SavedReportError.invalid }
            return try f.string("type") == "real" ? .real(v) : .date(Date(timeIntervalSinceReferenceDate: v))
        case "string": return .string(try raw.string())
        case "data-base64":
            guard let v = Data(base64Encoded: try raw.string()), v.base64EncodedString() == (try raw.string()) else { throw SavedReportError.invalid }; return .data(v)
        case "array": guard case .array(let a) = raw else { throw SavedReportError.invalid }; return .array(try a.map(value))
        case "dictionary": return .dictionary(try dictionary(raw))
        default: throw SavedReportError.invalid
        }
    }
}

private indirect enum JSONNode: Equatable {
    case object([String: JSONNode]), array([JSONNode]), string(String), number(String), boolean(Bool), null
    func object(_ keys: Set<String>) throws -> [String: JSONNode] {
        guard case .object(let f) = self, Set(f.keys) == keys else { throw SavedReportError.invalid }; return f
    }
    func string() throws -> String { guard case .string(let s) = self else { throw SavedReportError.invalid }; return s }
}
private extension Dictionary where Key == String, Value == JSONNode {
    func required(_ key: String) throws -> JSONNode { guard let v = self[key] else { throw SavedReportError.invalid }; return v }
    func string(_ key: String) throws -> String { try required(key).string() }
    func array(_ key: String) throws -> [JSONNode] { guard case .array(let a) = try required(key) else { throw SavedReportError.invalid }; return a }
}

/// Parses containers itself; Foundation is used only for individual bounded scalar tokens.
private struct BoundedJSON {
    let bytes: [UInt8]
    var position = 0
    var nodes = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { whitespace(); if position < bytes.count && bytes[position] == byte { position += 1; return true }; return false }
    mutating func parse() throws -> JSONNode { let result = try node(0); whitespace(); guard position == bytes.count else { throw SavedReportError.invalid }; return result }
    mutating func string() throws -> String {
        whitespace(); let start = position
        guard take(34) else { throw SavedReportError.invalid }
        while position < bytes.count {
            let b = bytes[position]; position += 1
            if b == 92 { guard position < bytes.count else { throw SavedReportError.invalid }; position += 1 }
            else if b == 34 {
                let token = Data(bytes[start..<position])
                let s = try JSONDecoder().decode(String.self, from: token)
                guard s.utf8.count <= 1_024 * 1_024 else { throw SavedReportError.limit }; return s
            }
        }
        throw SavedReportError.invalid
    }
    mutating func node(_ depth: Int) throws -> JSONNode {
        whitespace(); nodes += 1
        guard depth <= 96, nodes <= 100_000 else { throw SavedReportError.limit }
        guard position < bytes.count else { throw SavedReportError.invalid }
        if take(123) {
            var fields: [String: JSONNode] = [:]
            if take(125) { return .object(fields) }
            repeat {
                let key = try string()
                guard fields[key] == nil, take(58) else { throw SavedReportError.invalid }
                fields[key] = try node(depth + 1)
                if take(125) { return .object(fields) }
            } while take(44)
            throw SavedReportError.invalid
        }
        if take(91) {
            var values: [JSONNode] = []
            if take(93) { return .array(values) }
            repeat { values.append(try node(depth + 1)); if take(93) { return .array(values) } } while take(44)
            throw SavedReportError.invalid
        }
        if bytes[position] == 34 { return .string(try string()) }
        let start = position
        while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
        let token = Data(bytes[start..<position]), text = String(decoding: token, as: UTF8.self)
        switch text { case "true": return .boolean(true); case "false": return .boolean(false); case "null": return .null; default: break }
        let number = try JSONDecoder().decode(Double.self, from: token)
        guard number.isFinite else { throw SavedReportError.invalid }
        return .number(text)
    }
}

/// Structural validation for chunked evidence envelopes. Existing report/snapshot
/// entry points and their 8 MiB ceiling remain unchanged.
public enum EvidenceEnvelopeJSON {
    public static func validate(_ data: Data) throws {
        guard data.count <= 32 * 1_024 * 1_024 else { throw SavedReportError.limit }
        var parser = BoundedJSON(data)
        _ = try parser.parse()
    }
}
