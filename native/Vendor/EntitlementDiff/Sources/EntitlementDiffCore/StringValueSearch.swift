import Foundation

/// Incremental literal UTF-8 search. Never materializes the complete source as bytes.
public struct StringValueSearch: Sendable {
    public static let queryByteLimit = 1_024
    public static let stepByteLimit = 32_768
    public enum InputError: Error { case invalidQuery, noMatch }
    public enum Direction: Sendable { case forward, backward }
    public private(set) var direction: Direction = .forward
    public struct Match: Sendable, Equatable {
        public let byteOffset: Int
        public let scalarOffset: Int
        public var pageIndex: Int { scalarOffset / LeafValueDocument.stringScalarsPerPage }
    }
    public enum Step: Sendable, Equatable { case match(Match), more, end }
    private let source: String
    private var pattern: [UInt8]
    private var prefix: [Int]
    private var index: String.UTF8View.Index
    private var matched = 0
    private var byteOffset = 0
    private var scalarOffset = 0
    private var scalarStarts: [Int]
    private let queryScalarCount: Int
    private var anchor: (index: String.UTF8View.Index, match: Match)?

    public init(source: String, query: String) throws {
        let bytes = Array(query.utf8.prefix(Self.queryByteLimit + 1))
        guard !bytes.isEmpty, bytes.count <= Self.queryByteLimit else { throw InputError.invalidQuery }
        self.source = source
        queryScalarCount = query.unicodeScalars.count
        pattern = bytes
        index = source.utf8.startIndex
        scalarStarts = Array(repeating: 0, count: bytes.count)
        prefix = Self.prefixTable(bytes)
    }

    private static func prefixTable(_ bytes: [UInt8]) -> [Int] {
        var table = Array(repeating: 0, count: bytes.count)
        var length = 0
        for i in bytes.indices.dropFirst() {
            while length > 0 && bytes[i] != bytes[length] { length = table[length - 1] }
            if bytes[i] == bytes[length] { length += 1 }
            table[i] = length
        }
        return table
    }

    /// Switch at the last match, excluding that start while retaining overlaps.
    /// Index movement and preprocessing are bounded by the query's 1,024 bytes.
    public func searching(_ direction: Direction) throws -> Self {
        guard direction != self.direction else { return self }
        guard let anchor else { throw InputError.noMatch }
        var next = self
        next.direction = direction
        next.pattern.reverse()
        next.prefix = Self.prefixTable(next.pattern)
        next.matched = 0
        let bytes = source.utf8
        if direction == .forward {
            next.index = bytes.index(after: anchor.index)
            next.byteOffset = anchor.match.byteOffset + 1
            next.scalarOffset = anchor.match.scalarOffset + 1
        } else {
            next.index = bytes.index(anchor.index, offsetBy: pattern.count - 1)
            next.byteOffset = anchor.match.byteOffset + pattern.count - 1
            next.scalarOffset = anchor.match.scalarOffset + queryScalarCount
            if bytes[next.index] & 0xC0 != 0x80 { next.scalarOffset -= 1 }
        }
        return next
    }

    /// Testable smaller budgets are allowed; callers cannot exceed the fixed step ceiling.
    public mutating func step(byteLimit: Int = Self.stepByteLimit) throws -> Step {
        try Task.checkCancellation()
        if direction == .backward { return try backwardStep(byteLimit: byteLimit) }
        let bytes = source.utf8
        let limit = min(Self.stepByteLimit, max(1, byteLimit))
        var consumed = 0
        while index != bytes.endIndex && consumed < limit {
            if consumed % 256 == 0 { try Task.checkCancellation() }
            let byte = bytes[index]
            // A valid query starts at a scalar boundary. Track scalar positions in a bounded ring.
            scalarStarts[byteOffset % pattern.count] = scalarOffset
            if byte & 0xC0 != 0x80 { scalarOffset += 1 }
            while matched > 0 && byte != pattern[matched] { matched = prefix[matched - 1] }
            if byte == pattern[matched] { matched += 1 }
            bytes.formIndex(after: &index)
            byteOffset += 1
            consumed += 1
            if matched == pattern.count {
                let start = byteOffset - pattern.count
                let scalar = scalarStarts[start % pattern.count]
                matched = prefix[matched - 1] // Preserve overlapping matches for Find Next.
                let match = Match(byteOffset: start, scalarOffset: scalar)
                anchor = (bytes.index(index, offsetBy: -pattern.count), match)
                return .match(match)
            }
        }
        return index == bytes.endIndex ? .end : .more
    }

    /// Uses the retained match anchor: at most 24 scalars per context side,
    /// 48 displayed match scalars and 1,024 bytes to locate the match end.
    /// Escaping is performed once over these bounded fragments.
    public func matchContextPreview() -> String? {
        guard let anchor else { return nil }
        let scalars = source.unicodeScalars
        let start = anchor.index
        let end = source.utf8.index(start, offsetBy: pattern.count)
        var before = start
        for _ in 0..<24 {
            guard before != scalars.startIndex else { break }
            scalars.formIndex(before: &before)
        }
        var after = end
        for _ in 0..<24 {
            guard after != scalars.endIndex else { break }
            scalars.formIndex(after: &after)
        }
        var shownEnd = start
        for _ in 0..<48 {
            guard shownEnd != end else { break }
            scalars.formIndex(after: &shownEnd)
        }
        let prefix = before == scalars.startIndex ? "" : "…"
        let suffix = after == scalars.endIndex ? "" : "…"
        let matchSuffix = shownEnd == end ? "" : "…[match continues]"
        return prefix + DisplayText.escaped(String(scalars[before..<start]))
            + "⟦" + DisplayText.escaped(String(scalars[start..<shownEnd])) + matchSuffix + "⟧"
            + DisplayText.escaped(String(scalars[end..<after])) + suffix
    }

    private mutating func backwardStep(byteLimit: Int) throws -> Step {
        let bytes = source.utf8
        let limit = min(Self.stepByteLimit, max(1, byteLimit))
        var consumed = 0
        while index != bytes.startIndex && consumed < limit {
            if consumed % 256 == 0 { try Task.checkCancellation() }
            bytes.formIndex(before: &index)
            byteOffset -= 1
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 { scalarOffset -= 1 }
            while matched > 0 && byte != pattern[matched] { matched = prefix[matched - 1] }
            if byte == pattern[matched] { matched += 1 }
            consumed += 1
            if matched == pattern.count {
                let match = Match(byteOffset: byteOffset, scalarOffset: scalarOffset)
                anchor = (index, match)
                matched = prefix[matched - 1]
                return .match(match)
            }
        }
        return index == bytes.startIndex ? .end : .more
    }

}
