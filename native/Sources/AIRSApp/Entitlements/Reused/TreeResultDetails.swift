import EntitlementDiffModel
import Foundation

/// Incremental, ASCII-only lossless record. Never walks the source-string prefix.
enum TreeResultDetails {
    static let byteLimit = 65_536
    enum Failure: Error { case outputLimit }
    static func text(key: String, hit: EntitlementTreeSearch.Hit, query: String,
                     complete: Bool, limited: Bool, scope: EntitlementTreeSearch.Scope = .both) throws -> String {
        var output = ""
        var byteCount = 0
        func append(_ text: String) throws {
            guard byteCount + text.utf8.count <= byteLimit else { throw Failure.outputLimit }
            byteCount += text.utf8.count
            output += text
        }
        func escaped(_ text: String) throws {
            try append("\"")
            for scalar in text.unicodeScalars { try append("\\u{\(String(scalar.value, radix: 16, uppercase: true))}") }
            try append("\"")
        }
        try append("Tree text result details\nText encoding: complete Unicode scalar escapes; no normalization.\nEntitlement key: ")
        try escaped(key)
        try append("\nSide: \(hit.side.label)\nPath root: Value\nPath segment count: \(hit.path.count)\n")
        for (ordinal, segment) in hit.path.enumerated() {
            switch segment {
            case .key(let key):
                try append("Segment \(ordinal + 1) dictionary key: "); try escaped(key); try append("\n")
            case .index(let index): try append("Segment \(ordinal + 1) array index (0-based): \(index)\n")
            }
        }
        try append("Match UTF-8 byte start (1-based): \(hit.match.byteOffset + 1)\nMatch Unicode scalar start (1-based): \(hit.match.scalarOffset + 1)\nMatch byte length: \(hit.queryByteCount)\nMatched text: ")
        // The selected hit belongs to this exact literal query and search generation.
        try escaped(query)
        try append("\nMatched UTF-8 bytes:")
        for byte in query.utf8 { try append(String(format: " %02X", byte)) }
        try append("\nSearch scope: \(scope.rawValue)\nTree search status: \(limited ? "incomplete (limit reached)" : complete ? "complete" : "incomplete (continuation available)")\nFirst occurrence per string leaf; not all occurrences.\n")
        return output
    }
}
