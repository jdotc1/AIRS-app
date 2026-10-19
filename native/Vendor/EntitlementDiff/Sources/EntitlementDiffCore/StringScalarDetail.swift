import Foundation

/// One captured scalar or EOF. Formatting never reads the source or inserts invisible glyphs.
public struct StringScalarDetail: Sendable, Equatable {
    public let scalar: Unicode.Scalar?
    public init(scalar: Unicode.Scalar?) { self.scalar = scalar }
    public var scalarLabel: String {
        guard let scalar else { return "End of string" }
        let hex = String(format: "%04X", scalar.value)
        return "U+\(hex) · \\u{\(hex)}"
    }
    public var utf8Bytes: String? {
        guard let scalar else { return nil }
        return String(scalar).utf8.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
