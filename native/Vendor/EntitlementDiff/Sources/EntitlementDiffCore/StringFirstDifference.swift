import Foundation

/// Explicit bounded comparison of captured originals; no normalization or whole-source byte arrays.
public struct StringFirstDifference: Sendable {
    public static let stepByteLimit = 32_768
    public struct Position: Sendable, Equatable {
        public let byteOffset: Int
        public let currentByteOffset: Int
        public var previousByteOffset: Int { byteOffset }
        public let scalarOffset: Int
        public let previousScalar: Unicode.Scalar?
        public let currentScalar: Unicode.Scalar?
        init(byteOffset: Int, scalarOffset: Int, previousScalar: Unicode.Scalar?, currentScalar: Unicode.Scalar?, currentByteOffset: Int? = nil) {
            self.byteOffset = byteOffset; self.currentByteOffset = currentByteOffset ?? byteOffset
            self.scalarOffset = scalarOffset; self.previousScalar = previousScalar; self.currentScalar = currentScalar
        }
        public var previousByteCount: Int { previousScalar.map { String($0).utf8.count } ?? 0 }
        public var currentByteCount: Int { currentScalar.map { String($0).utf8.count } ?? 0 }
        public var previousDetail: StringScalarDetail { StringScalarDetail(scalar: previousScalar) }
        public var currentDetail: StringScalarDetail { StringScalarDetail(scalar: currentScalar) }
        public var pageIndex: Int { scalarOffset / LeafValueDocument.stringScalarsPerPage }
    }
    public enum Step: Sendable, Equatable { case more, equal, difference(Position) }
    private let previous: String
    private let current: String
    private var previousIndex: String.UnicodeScalarView.Index
    private var currentIndex: String.UnicodeScalarView.Index
    private var byteOffset = 0
    private var scalarOffset = 0
    private var currentByteOffset = 0
    private var foundDifference: Position?
    private var exhausted = false

    public init(previous: String, current: String) {
        self.previous = previous; self.current = current
        previousIndex = previous.unicodeScalars.startIndex
        currentIndex = current.unicodeScalars.startIndex
    }

    /// Budget counts both sources' UTF-8 bytes; at least one pair (up to eight bytes) fits.
    public mutating func step(byteLimit: Int = Self.stepByteLimit) throws -> Step {
        try Task.checkCancellation()
        if exhausted { return .equal }
        let limit = min(Self.stepByteLimit, max(8, byteLimit))
        let left = previous.unicodeScalars, right = current.unicodeScalars
        var consumed = 0, pairs = 0
        while true {
            if pairs % 64 == 0 { try Task.checkCancellation() }
            let aEnded = previousIndex == left.endIndex, bEnded = currentIndex == right.endIndex
            if aEnded && bEnded { return .equal }
            // Reserve the maximum scalar-pair size before reading either source.
            guard limit - consumed >= 8 else { return .more }
            let a = aEnded ? nil : left[previousIndex]
            let b = bEnded ? nil : right[currentIndex]
            let aBytes = a.map { String($0).utf8.count } ?? 0
            let bBytes = b.map { String($0).utf8.count } ?? 0
            guard consumed + aBytes + bBytes <= limit else { return .more }
            if a != b {
                let found = Position(byteOffset: byteOffset, scalarOffset: scalarOffset,
                                     previousScalar: a, currentScalar: b, currentByteOffset: currentByteOffset)
                foundDifference = found
                return .difference(found)
            }
            consumed += aBytes + bBytes; pairs += 1
            byteOffset += aBytes; currentByteOffset += bBytes; scalarOffset += 1
            left.formIndex(after: &previousIndex); right.formIndex(after: &currentIndex)
        }
    }
    /// Advance only past a captured mismatch; EOF is one terminal difference.
    @discardableResult
    public mutating func movePastDifference() -> Bool {
        guard let found = foundDifference else { return false }
        foundDifference = nil
        if found.previousScalar == nil || found.currentScalar == nil {
            exhausted = true
        } else {
            previous.unicodeScalars.formIndex(after: &previousIndex)
            current.unicodeScalars.formIndex(after: &currentIndex)
            byteOffset += found.previousByteCount
            currentByteOffset += found.currentByteCount
            scalarOffset += 1
        }
        return true
    }

}
