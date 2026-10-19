import Foundation

/// KMP cursor retains partial matches across bounded portions, including overlapping matches.
public struct HexByteCursor: Sendable {
    public enum Step: Sendable, Equatable { case match(Int), more, end }
    public static let byteLimit = 32_768
    public let source: Data
    public private(set) var pattern: [UInt8]
    public enum Direction: Sendable { case forward, backward }
    public private(set) var direction: Direction = .forward
    private var anchor: Int?
    private var failure: [Int]
    private var offset = 0
    private var matched = 0
    public init(source: Data, query: String) throws {
        let raw = Array(query.utf8.prefix(385))
        guard !raw.isEmpty, raw.count <= 383 else { throw Invalid.query }
        var bytes: [UInt8] = [], high: UInt8?
        for c in raw {
            if c == 32 { guard high == nil else { throw Invalid.query }; continue }
            let n: UInt8
            switch c {
            case 48...57: n = c - 48
            case 65...70: n = c - 55
            case 97...102: n = c - 87
            default: throw Invalid.query
            }
            if let h = high { bytes.append(h * 16 + n); high = nil }
            else { high = n }
        }
        guard high == nil, !bytes.isEmpty, bytes.count <= 128 else { throw Invalid.query }
        pattern = bytes; self.source = source
        failure = Self.prefixTable(bytes)
    }
    private static func prefixTable(_ bytes: [UInt8]) -> [Int] {
        var table = Array(repeating: 0, count: bytes.count), prefix = 0
        for i in bytes.indices.dropFirst() {
            while prefix > 0 && bytes[i] != bytes[prefix] { prefix = table[prefix - 1] }
            if bytes[i] == bytes[prefix] { prefix += 1 }
            table[i] = prefix
        }
        return table
    }
    public enum Invalid: Error { case query, noMatch }
    /// Excludes the selected start; reversing at its end retains overlapping matches.
    public func searching(_ requested: Direction) throws -> Self {
        guard requested != direction else { return self }
        guard let anchor else { throw Invalid.noMatch }
        var next = self
        next.direction = requested; next.pattern.reverse()
        next.failure = Self.prefixTable(next.pattern); next.matched = 0
        next.offset = requested == .forward ? anchor + 1 : anchor + pattern.count - 1
        return next
    }
    public mutating func step(limit: Int = Self.byteLimit) throws -> Step {
        try Task.checkCancellation()
        if direction == .backward { return try backwardStep(limit: limit) }
        let budget = min(Self.byteLimit, max(1, limit))
        var consumed = 0
        while offset < source.count && consumed < budget {
            if consumed % 256 == 0 { try Task.checkCancellation() }
            let byte = source[source.index(source.startIndex, offsetBy: offset)]
            while matched > 0 && byte != pattern[matched] { matched = failure[matched - 1] }
            if byte == pattern[matched] { matched += 1 }
            offset += 1; consumed += 1
            if matched == pattern.count {
                let start = offset - matched
                matched = failure[matched - 1]
                anchor = start
                return .match(start)
            }
        }
        try Task.checkCancellation()
        return offset == source.count ? .end : .more
    }
    private mutating func backwardStep(limit: Int) throws -> Step {
        let budget = min(Self.byteLimit, max(1, limit))
        var consumed = 0
        while offset > 0 && consumed < budget {
            if consumed % 256 == 0 { try Task.checkCancellation() }
            offset -= 1
            let byte = source[source.index(source.startIndex, offsetBy: offset)]
            while matched > 0 && byte != pattern[matched] { matched = failure[matched - 1] }
            if byte == pattern[matched] { matched += 1 }
            consumed += 1
            if matched == pattern.count {
                anchor = offset; matched = failure[matched - 1]
                return .match(offset)
            }
        }
        try Task.checkCancellation()
        return offset == 0 ? .end : .more
    }
}

