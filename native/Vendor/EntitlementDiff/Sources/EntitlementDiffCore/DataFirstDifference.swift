import Foundation

/// Bounded original-byte comparison; Data storage is shared without flattening or decoding.
public struct DataFirstDifference: Sendable {
    public static let stepByteLimit = 32_768
    public struct Position: Sendable, Equatable {
        public let byteOffset: Int
        public let previousByte: UInt8?
        public let currentByte: UInt8?
        public var pageIndex: Int { byteOffset / LeafValueDocument.dataBytesPerPage }
        public var previousLabel: String { previousByte.map { String(format: "%02X", $0) } ?? "End of data" }
        public var currentLabel: String { currentByte.map { String(format: "%02X", $0) } ?? "End of data" }
    }
    public enum Step: Sendable, Equatable { case more, equal, difference(Position) }
    private let previous: Data
    private let current: Data
    private var previousIndex: Data.Index
    private var currentIndex: Data.Index
    private var byteOffset = 0
    private var foundDifference: Position?
    private var exhausted = false

    public init(previous: Data, current: Data) {
        self.previous = previous; self.current = current
        previousIndex = previous.startIndex; currentIndex = current.startIndex
    }
    /// Counts both inputs' bytes; reserve two bytes before reading a pair.
    public mutating func step(byteLimit: Int = Self.stepByteLimit) throws -> Step {
        try Task.checkCancellation()
        if exhausted { return .equal }
        let limit = min(Self.stepByteLimit, max(2, byteLimit))
        var consumed = 0, pairs = 0
        while true {
            if pairs % 256 == 0 { try Task.checkCancellation() }
            let aEnded = previousIndex == previous.endIndex, bEnded = currentIndex == current.endIndex
            if aEnded && bEnded { return .equal }
            guard limit - consumed >= 2 else { return .more }
            let a = aEnded ? nil : previous[previousIndex]
            let b = bEnded ? nil : current[currentIndex]
            if a != b {
                let found = Position(byteOffset: byteOffset, previousByte: a, currentByte: b)
                foundDifference = found
                return .difference(found)
            }
            previous.formIndex(after: &previousIndex); current.formIndex(after: &currentIndex)
            byteOffset += 1; consumed += 2; pairs += 1
        }
    }
    /// Explicitly skip the already-read mismatch. EOF is a single terminal difference.
    /// No prefix rescan or trailing-byte walk is required.
    @discardableResult
    public mutating func movePastDifference() -> Bool {
        guard let found = foundDifference else { return false }
        foundDifference = nil
        if found.previousByte == nil || found.currentByte == nil {
            exhausted = true
        } else {
            previous.formIndex(after: &previousIndex)
            current.formIndex(after: &currentIndex)
            byteOffset += 1
        }
        return true
    }

}
