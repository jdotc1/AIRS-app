import Foundation

/// Explicit immediate-child navigation. Never traverses or compares descendant values.
/// Cursors index the immutable sorted entry arrays, so each next page merges at most 50 keys.
public struct InspectorBranchNavigator: Sendable {
    public static let pageSize = 50
    private struct Cursor: Sendable { var old = 0; var new = 0; var ordinal = 0 }
    private struct Frame: Sendable {
        let token = UUID()
        let root: InspectorRow
        var cursor = Cursor()
        var history: [Cursor] = []
    }
    private var frame: Frame
    private var ancestors: [Frame] = []
    public private(set) var rows: [InspectorRow] = []
    public private(set) var exactChild: InspectorRow?
    private var next = Cursor()
    public private(set) var hasNext = false
    public var root: InspectorRow { frame.root }
    public var depth: Int { ancestors.count }
    public var offset: Int { frame.cursor.ordinal }
    public var canGoBack: Bool { !ancestors.isEmpty }
    public var hasPrevious: Bool { offset > 0 }
    /// Opaque frame identity prevents an old menu action from resolving in a new branch/session.
    public struct Ancestor: Identifiable, Sendable {
        public let id: UUID
        public let level: Int
        public let label: String
    }
    public var rootAncestor: Ancestor? {
        ancestors.first.map { Ancestor(id: $0.token, level: 0, label: "Root") }
    }
    /// Nearest twelve non-root ancestors; Root is a separate direct action.
    public var recentAncestors: [Ancestor] {
        let start = max(1, ancestors.count - 12)
        guard start < ancestors.count else { return [] }
        return (start..<ancestors.count).reversed().map {
            Ancestor(id: ancestors[$0].token, level: $0, label: ancestors[$0].root.label)
        }
    }
    @discardableResult
    public mutating func jump(to ancestor: Ancestor) -> Bool {
        guard ancestors.indices.contains(ancestor.level),
              ancestors[ancestor.level].token == ancestor.id else { return false }
        frame = ancestors[ancestor.level]
        ancestors.removeSubrange(ancestor.level...)
        refresh()
        return true
    }

    public var arrayCount: Int? {
        switch (root.previous, root.current) {
        case (.array(let a), .array(let b)): max(a.count, b.count)
        case (.array(let a), .none): a.count
        case (.none, .array(let b)): b.count
        default: nil
        }
    }

    private var dictionaryEntries: ([EntitlementEntry], [EntitlementEntry])? {
        switch (root.previous, root.current) {
        case (.dictionary(let a), .dictionary(let b)): (a.entries, b.entries)
        case (.dictionary(let a), .none): (a.entries, [])
        case (.none, .dictionary(let b)): ([], b.entries)
        default: nil
        }
    }
    public var canFindChildKey: Bool { dictionaryEntries != nil }

    public mutating func clearExactChild() { exactChild = nil }

    /// Two lower-bound searches over immediate children; no normalization or subtree comparison.
    @discardableResult
    public mutating func findExactChild(_ key: String) -> Bool {
        exactChild = nil
        guard let (a, b) = dictionaryEntries else { return false }
        func lowerBound(_ entries: [EntitlementEntry]) -> Int {
            var low = 0, high = entries.count
            while low < high {
                let mid = low + (high - low) / 2
                if entries[mid].key.utf8.lexicographicallyPrecedes(key.utf8) { low = mid + 1 }
                else { high = mid }
            }
            return low
        }
        let i = lowerBound(a), j = lowerBound(b)
        let old = i < a.count && a[i].key.utf8.elementsEqual(key.utf8) ? a[i].value : nil
        let new = j < b.count && b[j].key.utf8.elementsEqual(key.utf8) ? b[j].value : nil
        guard old != nil || new != nil else { return false }
        let label = EntitlementValue.string(key).preview(maxCharacters: 256)
        exactChild = .init(id: root.id + "/k\(i):\(j)", depth: 0, label: label,
                          displayPath: String((root.displayPath + " / " + label).unicodeScalars.suffix(512)),
                          previous: old, current: new,
                          expandable: Self.isContainer(old) || Self.isContainer(new))
        return true
    }

    public init(previous: EntitlementValue?, current: EntitlementValue?) {
        frame = Frame(root: .init(id: "root", depth: 0, label: "Value", displayPath: "Value",
                                 previous: previous, current: current,
                                 expandable: Self.isContainer(previous) || Self.isContainer(current)))
        refresh()
    }

    public mutating func nextPage() {
        guard hasNext else { return }
        frame.history.append(frame.cursor)
        frame.cursor = next
        refresh()
    }

    public mutating func previousPage() {
        guard hasPrevious else { return }
        if arrayCount != nil {
            let index = max(0, offset - Self.pageSize)
            frame.cursor = Cursor(old: index, new: index, ordinal: index)
            frame.history = []
        } else if let cursor = frame.history.popLast() { frame.cursor = cursor }
        refresh()
    }

    public mutating func firstPage() {
        frame.cursor = Cursor(); frame.history = []; refresh()
    }

    @discardableResult
    public mutating func goToArrayIndex(_ index: Int) -> Bool {
        guard let count = arrayCount, index >= 0, index < count else { return false }
        frame.cursor = Cursor(old: index, new: index, ordinal: index)
        frame.history = []
        refresh()
        return true
    }

    @discardableResult
    public mutating func enter(_ id: String) -> Bool {
        guard let row = rows.first(where: { $0.id == id }) ?? (exactChild?.id == id ? exactChild : nil),
              row.hasContainerValue else { return false }
        ancestors.append(frame)
        frame = Frame(root: row)
        refresh()
        return true
    }

    public mutating func back() {
        guard let parent = ancestors.popLast() else { return }
        frame = parent
        refresh()
    }

    private static func isContainer(_ value: EntitlementValue?) -> Bool {
        switch value { case .array, .dictionary: true; default: false }
    }

    private mutating func refresh() {
        exactChild = nil
        let parent = root
        var cursor = frame.cursor
        var result: [InspectorRow] = []
        func append(_ old: EntitlementValue?, _ new: EntitlementValue?, _ identity: String, _ label: String) {
            // Identity uses immutable entry positions, never truncated/canonically equivalent labels.
            let display = parent.displayPath + " / " + label
            result.append(.init(id: parent.id + identity, depth: 0, label: label,
                                displayPath: String(display.unicodeScalars.suffix(512)),
                                previous: old, current: new,
                                expandable: Self.isContainer(old) || Self.isContainer(new)))
            cursor.ordinal += 1
        }
        func arrays(_ a: [EntitlementValue], _ b: [EntitlementValue]) {
            let end = min(max(a.count, b.count), cursor.ordinal + Self.pageSize)
            for i in cursor.ordinal..<end {
                append(i < a.count ? a[i] : nil, i < b.count ? b[i] : nil, "/i\(i)", "[\(i)]")
            }
            cursor.old = cursor.ordinal; cursor.new = cursor.ordinal
            hasNext = cursor.ordinal < max(a.count, b.count)
        }
        func dictionaries(_ a: [EntitlementEntry], _ b: [EntitlementEntry]) {
            while result.count < Self.pageSize && (cursor.old < a.count || cursor.new < b.count) {
                let i = cursor.old, j = cursor.new
                let key: String, old: EntitlementValue?, new: EntitlementValue?
                if i == a.count { key = b[j].key; old = nil; new = b[j].value; cursor.new += 1 }
                else if j == b.count { key = a[i].key; old = a[i].value; new = nil; cursor.old += 1 }
                else if a[i].key.utf8.elementsEqual(b[j].key.utf8) {
                    key = a[i].key; old = a[i].value; new = b[j].value
                    cursor.old += 1; cursor.new += 1
                } else if a[i].key.utf8.lexicographicallyPrecedes(b[j].key.utf8) {
                    key = a[i].key; old = a[i].value; new = nil; cursor.old += 1
                } else { key = b[j].key; old = nil; new = b[j].value; cursor.new += 1 }
                append(old, new, "/k\(i):\(j)", EntitlementValue.string(key).preview(maxCharacters: 256))
            }
            hasNext = cursor.old < a.count || cursor.new < b.count
        }
        hasNext = false
        switch (parent.previous, parent.current) {
        case (.array(let a), .array(let b)): arrays(a, b)
        case (.array(let a), .none): arrays(a, [])
        case (.none, .array(let b)): arrays([], b)
        case (.dictionary(let a), .dictionary(let b)): dictionaries(a.entries, b.entries)
        case (.dictionary(let a), .none): dictionaries(a.entries, [])
        case (.none, .dictionary(let b)): dictionaries([], b.entries)
        default:
            // Type replacements retain separate structures, never pairing a key with an index.
            if Self.isContainer(parent.previous) { append(parent.previous, nil, "/previous", "Previous structure") }
            if Self.isContainer(parent.current) { append(nil, parent.current, "/current", "Current structure") }
        }
        rows = result
        next = cursor
    }
}

extension InspectorRow {
    public var hasContainerValue: Bool {
        switch previous { case .array, .dictionary: return true; default: break }
        switch current { case .array, .dictionary: return true; default: return false }
    }
}
