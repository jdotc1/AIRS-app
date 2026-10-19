import Foundation

/// A fixed window of original bytes, prepared once for a saved difference.
/// Offsets are relative to the value, including Data with nonzero start indices.
public struct DataDifferenceContext: Sendable, Equatable {
    public static let surroundingByteLimit = 16
    public let startByteOffset: Int
    public let byteCount: Int
    public let beforeHex: String
    public let markedHex: String
    public let afterHex: String
    public let rangeLabel: String

    public init?(data: Data, byteOffset: Int) {
        guard byteOffset >= 0, byteOffset <= data.count else { return nil }
        let beforeCount = min(Self.surroundingByteLimit, byteOffset)
        let isEnd = byteOffset == data.count
        let afterCount = isEnd ? 0 : min(Self.surroundingByteLimit, data.count - byteOffset - 1)
        startByteOffset = byteOffset - beforeCount
        byteCount = beforeCount + (isEnd ? 0 : 1) + afterCount
        let start = data.index(data.startIndex, offsetBy: startByteOffset)
        let marked = data.index(start, offsetBy: beforeCount)
        beforeHex = Self.hex(data[start..<marked])
        markedHex = isEnd ? "[EOF]" : "[" + Self.byte(data[marked]) + "]"
        if isEnd {
            afterHex = ""
        } else {
            let afterStart = data.index(after: marked)
            let end = data.index(afterStart, offsetBy: afterCount)
            afterHex = Self.hex(data[afterStart..<end])
        }
        if data.isEmpty {
            rangeLabel = "Empty data · EOF at byte 1"
        } else {
            let range = "Bytes \(startByteOffset + 1)–\(startByteOffset + byteCount)"
            rangeLabel = range + (isEnd ? " · EOF at byte \(byteOffset + 1)" : " · brackets mark byte \(byteOffset + 1)")
        }
    }

    private static func byte(_ value: UInt8) -> String { String(format: "%02X", value) }
    private static func hex(_ bytes: Data.SubSequence) -> String {
        bytes.map { byte($0) }.joined(separator: " ")
    }
}
