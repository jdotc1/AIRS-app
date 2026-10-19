import Foundation
import EntitlementDiffCore

/// Bounded summaries of captured results only; no source values, paths or rescans.
enum CurrentDifferenceDetails {
    static let byteLimit = 2048
    static func string(_ position: StringFirstDifference.Position, ordinal: Int) -> String {
        func side(_ name: String, offset: Int, detail: StringScalarDetail) -> String {
            "\(name) UTF-8 byte: \(offset + 1)\n\(name): \(detail.scalarLabel)\n\(name) UTF-8: \(detail.utf8Bytes ?? "EOF")"
        }
        return "String difference \(ordinal)\nPositions are 1-based; scalars compare positionally without alignment.\nScalar position: \(position.scalarOffset + 1)\n" +
            side("Previous", offset: position.previousByteOffset, detail: position.previousDetail) + "\n" +
            side("Current", offset: position.currentByteOffset, detail: position.currentDetail) + "\n"
    }
    static func data(_ position: DataFirstDifference.Position, ordinal: Int,
                     previous: DataDifferenceContext?, current: DataDifferenceContext?) -> String {
        func side(_ name: String, byte: String, context: DataDifferenceContext?) -> String {
            var text = "\(name): \(byte)"
            if let context {
                text += "\n\(name) context: \(context.rangeLabel)\n" +
                    [context.beforeHex, context.markedHex, context.afterHex].filter { !$0.isEmpty }.joined(separator: " ")
            }
            return text
        }
        return "Data difference \(ordinal)\nByte position: \(position.byteOffset + 1) (1-based)\n" +
            side("Previous", byte: position.previousLabel, context: previous) + "\n" +
            side("Current", byte: position.currentLabel, context: current) + "\n"
    }
}
