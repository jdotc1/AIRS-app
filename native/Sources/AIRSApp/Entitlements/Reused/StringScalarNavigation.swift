import Foundation
import EntitlementDiffCore
import EntitlementDiffModel

/// Pane-local navigation, independent of literal search and difference history.
struct StringScalarNavigation {
    private(set) var input = "1"
    private(set) var position: LeafValueDocument.ScalarPosition?
    private(set) var error: String?
    private(set) var revision = UUID()
    mutating func setInput(_ text: String) {
        input = String(decoding: text.utf8.prefix(21), as: UTF8.self); error = nil
    }
    @discardableResult
    mutating func go(document: LeafValueDocument) -> Bool {
        let bytes = Array(input.utf8.prefix(21))
        guard let count = document.stringScalarCount else { return false }
        guard !bytes.isEmpty, bytes.count <= 20, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(input), number >= 1,
              let found = document.scalarPosition(at: number - 1) else {
            error = "Enter a scalar position from 1 through \(count + 1) (EOF)."; return false
        }
        position = found; error = nil; revision = UUID(); return true
    }
    enum Direction { case previous, next }
    func canStep(_ direction: Direction, document: LeafValueDocument) -> Bool {
        guard let position, let count = document.stringScalarCount else { return false }
        return direction == .previous ? position.scalarOffset > 0 : position.scalarOffset < count
    }
    @discardableResult
    mutating func step(_ direction: Direction, document: LeafValueDocument) -> Bool {
        guard canStep(direction, document: document), let position,
              let found = document.scalarPosition(at: position.scalarOffset + (direction == .previous ? -1 : 1)) else { return false }
        self.position = found; input = String(found.scalarOffset + 1); error = nil; revision = UUID()
        return true
    }
    /// Reuses the captured position without parsing pending input or rescanning.
    @discardableResult
    mutating func reveal() -> Bool {
        guard let position else { return false }
        input = String(position.scalarOffset + 1); error = nil; revision = UUID()
        return true
    }
    static let copyByteLimit = 1024
    /// Captured original scalar/EOF only; never pending or rejected field text.
    func copyText(side: ComparisonSide) -> String? {
        guard let position else { return nil }
        return "\(side.label) viewed scalar details\nScalar position: \(position.scalarOffset + 1) (1-based)\n" +
            "UTF-8 byte position: \(position.byteOffset + 1) (1-based)\n" +
            "Scalar: \(position.detail.scalarLabel)\nUTF-8: \(position.detail.utf8Bytes ?? "EOF")\n" +
            "Positions refer to original Unicode scalars, without normalization.\n"
    }
    mutating func reset() { self = .init() }
}
