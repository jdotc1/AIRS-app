import EntitlementDiffCore
import Foundation

/// Resumable depth-first search: 64 traversal operations and one 32KiB data
/// portion per action. Captured values are immutable; child arrays are never flattened.
public struct EntitlementTreeHexSearch: Sendable {
    public typealias Scope = EntitlementTreeSearch.Scope
    public typealias Segment = EntitlementTreeSearch.Segment
    public let scope: Scope
    public struct Hit: Identifiable, Sendable {
        public let id = UUID()
        public let side: ComparisonSide
        public let path: [Segment]
        public let value: Data
        public let byteOffset: Int
        public let queryByteCount: Int
        public let contextPreview: String
        public var pathPreview: String {
            "Value" + path.map {
                switch $0 {
                case .key(let key): "." + DisplayText.quoted(String(key.unicodeScalars.prefix(80)))
                case .index(let index): "[\(index)]"
                }
            }.joined()
        }
    }
    private struct Frame: Sendable { let value: EntitlementValue; let path: [Segment]; var next = 0 }
    private struct Active: Sendable { var cursor: HexByteCursor; let path: [Segment]; let value: Data }
    private let query: String
    private let queryByteCount: Int
    private var roots: [(ComparisonSide, EntitlementValue)]
    private var rootIndex = 0
    private var stack: [Frame] = []
    private var active: Active?
    public private(set) var hits: [Hit] = []
    public private(set) var complete = false
    public private(set) var limited = false
    public private(set) var visited = 0
    public static let resultLimit = 200
    public static let depthLimit = 128

    public init(previous: EntitlementValue?, current: EntitlementValue?, query: String, scope: Scope = .both) throws {
        let validated = try HexByteCursor(source: Data(), query: query)
        self.scope = scope
        self.query = query; queryByteCount = validated.pattern.count
        roots = []
        if scope != .current, let previous { roots.append((.previous, previous)) }
        if scope != .previous, let current { roots.append((.current, current)) }
    }
    private static func context(_ data: Data, offset: Int, length: Int) -> String {
        let lower = max(0, offset - 8), upper = min(data.count, offset + length + 8)
        func hex(_ range: Range<Int>) -> String {
            range.map { String(format: "%02X", data[data.index(data.startIndex, offsetBy: $0)]) }.joined(separator: " ")
        }
        return (lower > 0 ? "… " : "") + hex(lower..<offset) + " [" + hex(offset..<(offset + length)) + "] " + hex((offset + length)..<upper) + (upper < data.count ? " …" : "")
    }
    public mutating func step() throws {
        guard !complete, !limited else { return }
        for _ in 0..<64 {
            try Task.checkCancellation()
            if var work = active {
                let result = try work.cursor.step()
                switch result {
                case .match(let offset):
                    hits.append(Hit(side: roots[rootIndex].0, path: work.path, value: work.value,
                                    byteOffset: offset, queryByteCount: queryByteCount, contextPreview: Self.context(work.value, offset: offset, length: queryByteCount)))
                    active = nil
                    if hits.count == Self.resultLimit { limited = true }
                case .more: active = work
                case .end: active = nil
                }
                if active == nil, stack.isEmpty { rootIndex += 1 }
                return // At most one data portion across the entire action.
            }
            if stack.isEmpty {
                guard rootIndex < roots.count else { complete = true; return }
                stack.append(Frame(value: roots[rootIndex].1, path: [])); visited += 1
            }
            let i = stack.count - 1
            let frame = stack[i]
            switch frame.value {
            case .data(let bytes):
                stack.removeLast()
                active = Active(cursor: try HexByteCursor(source: bytes, query: query), path: frame.path, value: bytes)
            case .array(let values):
                if frame.next < values.count {
                    stack[i].next += 1
                    guard frame.path.count < Self.depthLimit else { limited = true; return }
                    stack.append(Frame(value: values[frame.next], path: frame.path + [.index(frame.next)])); visited += 1
                } else { stack.removeLast() }
            case .dictionary(let dictionary):
                if frame.next < dictionary.entries.count {
                    stack[i].next += 1
                    guard frame.path.count < Self.depthLimit else { limited = true; return }
                    let entry = dictionary.entries[frame.next]
                    stack.append(Frame(value: entry.value, path: frame.path + [.key(entry.key)])); visited += 1
                } else { stack.removeLast() }
            default: stack.removeLast()
            }
            if stack.isEmpty, active == nil { rootIndex += 1 }
        }
    }
}
