import EntitlementDiffCore
import Foundation

/// Resumable depth-first search: 64 traversal operations and one 32KiB string
/// portion per action. Captured values are immutable; child arrays are never flattened.
public struct EntitlementTreeSearch: Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        case both = "Both", previous = "Previous", current = "Current"
    }
    public let scope: Scope
    public enum Segment: Sendable, Equatable {
        case key(String), index(Int)
        public static func == (a: Self, b: Self) -> Bool {
            switch (a,b) {
            case let (.key(x),.key(y)): x.utf8.elementsEqual(y.utf8)
            case let (.index(x),.index(y)): x == y
            default: false
            }
        }
    }
    public struct Hit: Identifiable, Sendable {
        public let id = UUID()
        public let side: ComparisonSide
        public let path: [Segment]
        public let value: String
        public let match: StringValueSearch.Match
        public let queryByteCount: Int
        public let contextPreview: String?
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
    private struct Active: Sendable { var cursor: StringValueSearch; let path: [Segment]; let value: String }
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
        _ = try StringValueSearch(source: "", query: query)
        self.scope = scope
        self.query = query; queryByteCount = query.utf8.count
        roots = []
        if scope != .current, let previous { roots.append((.previous, previous)) }
        if scope != .previous, let current { roots.append((.current, current)) }
    }
    public mutating func step() throws {
        guard !complete, !limited else { return }
        for _ in 0..<64 {
            try Task.checkCancellation()
            if var work = active {
                let result = try work.cursor.step()
                switch result {
                case .match(let match):
                    hits.append(Hit(side: roots[rootIndex].0, path: work.path, value: work.value,
                                    match: match, queryByteCount: queryByteCount, contextPreview: work.cursor.matchContextPreview()))
                    active = nil
                    if hits.count == Self.resultLimit { limited = true }
                case .more: active = work
                case .end: active = nil
                }
                if active == nil, stack.isEmpty { rootIndex += 1 }
                return // At most one string portion across the entire action.
            }
            if stack.isEmpty {
                guard rootIndex < roots.count else { complete = true; return }
                stack.append(Frame(value: roots[rootIndex].1, path: [])); visited += 1
            }
            let i = stack.count - 1
            let frame = stack[i]
            switch frame.value {
            case .string(let text):
                stack.removeLast()
                active = Active(cursor: try StringValueSearch(source: text, query: query), path: frame.path, value: text)
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
