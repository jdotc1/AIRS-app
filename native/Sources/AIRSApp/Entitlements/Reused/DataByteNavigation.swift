import Foundation
import EntitlementDiffCore
import EntitlementDiffModel

/// Pane-local manual context, independent of comparison history and its frontier.
struct DataByteNavigation {
    private(set) var input = "1"
    private(set) var context: DataDifferenceContext?
    private(set) var byteOffset: Int?
    private(set) var error: String?

    mutating func setInput(_ text: String) {
        input = String(decoding: text.utf8.prefix(21), as: UTF8.self)
        error = nil
    }
    @discardableResult
    mutating func go(data: Data) -> Bool {
        let bytes = Array(input.utf8.prefix(21))
        guard !bytes.isEmpty, bytes.count <= 20,
              bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(input), number >= 1,
              number - 1 <= data.count,
              let next = DataDifferenceContext(data: data, byteOffset: number - 1) else {
            error = "Enter a byte position from 1 through \(data.count + 1) (EOF)."
            return false
        }
        byteOffset = number - 1; context = next; error = nil
        return true
    }
    enum Direction { case previous, next }
    func canStep(_ direction: Direction, dataCount: Int) -> Bool {
        guard let byteOffset, byteOffset >= 0, byteOffset <= dataCount else { return false }
        return direction == .previous ? byteOffset > 0 : byteOffset < dataCount
    }
    @discardableResult
    mutating func step(_ direction: Direction, data: Data) -> Bool {
        guard canStep(direction, dataCount: data.count), let byteOffset else { return false }
        let offset = byteOffset + (direction == .previous ? -1 : 1)
        guard let next = DataDifferenceContext(data: data, byteOffset: offset) else { return false }
        self.byteOffset = offset; context = next; input = String(offset + 1); error = nil
        return true
    }
    /// Reuses the captured context without reading data or parsing pending input.
    @discardableResult
    mutating func reveal() -> Bool {
        guard let byteOffset, context != nil else { return false }
        input = String(byteOffset + 1); error = nil
        return true
    }
    /// Uses the last successful position, never pending or rejected field input.
    func copyText(side: ComparisonSide) -> String? {
        guard let context, let byteOffset else { return nil }
        let hex = [context.beforeHex, context.markedHex, context.afterHex]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return "\(side.label) viewed byte context\nByte position: \(byteOffset + 1) (1-based)\n" +
            "\(context.rangeLabel)\n\(hex)\nBrackets mark the viewed byte or EOF.\n"
    }
    static let copyByteLimit = 1024
    mutating func reset() { self = .init() }
}
