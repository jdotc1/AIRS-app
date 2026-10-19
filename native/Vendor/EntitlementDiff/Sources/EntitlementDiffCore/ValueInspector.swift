import Foundation

/// A bounded visible projection. Paths identify UTF-8 dictionary keys and positional array slots.
public struct InspectorRow: Identifiable, Sendable {
    public let id: String
    public let depth: Int
    public let label: String
    public let displayPath: String
    public let previous: EntitlementValue?
    public let current: EntitlementValue?
    public let expandable: Bool
    // Branch navigation leaves this nil: it does not classify entire subtrees.
    private let cachedKind: ChangeKind?
    init(id: String, depth: Int, label: String, displayPath: String,
         previous: EntitlementValue?, current: EntitlementValue?, expandable: Bool,
         cachedKind: ChangeKind? = nil) {
        self.id = id; self.depth = depth; self.label = label; self.displayPath = displayPath
        self.previous = previous; self.current = current; self.expandable = expandable
        self.cachedKind = cachedKind
    }
    public var kind: ChangeKind {
        if let cachedKind { return cachedKind }
        return Self.classify(previous, current)
    }
    private static func classify(_ previous: EntitlementValue?, _ current: EntitlementValue?) -> ChangeKind {
        if previous == nil { return .added }
        if current == nil { return .removed }
        return previous == current ? .unchanged : .changed
    }
    func classified() -> Self {
        guard cachedKind == nil else { return self }
        return .init(id: id, depth: depth, label: label, displayPath: displayPath,
                     previous: previous, current: current, expandable: expandable,
                     cachedKind: kind)
    }
    public static func summary(_ value: EntitlementValue?) -> String {
        switch value {
        case .array(let values): return "Array (\(values.count) items)"
        case .dictionary(let values): return "Dictionary (\(values.entries.count) keys)"
        case .none: return "Absent"
        default: return "\(value?.typeName ?? "Absent"): \(value?.preview(maxCharacters: 256) ?? "")"
        }
    }
}

public struct ValueInspector: Sendable {
    public let rows: [InspectorRow]
    public let limited: Bool
    public let hasNextPage: Bool
    public let pageOffset: Int
    public let matchingRowCount: Int
    public let searchIncomplete: Bool

    public init(previous: EntitlementValue?, current: EntitlementValue?, expanded: Set<String>,
                maxRows: Int = 200, maxDepth: Int = 12,
                query: String = "", changesOnly: Bool = false, offset: Int = 0) {
        var result: [InspectorRow] = []
        var hitLimit = false
        var visited = 0
        var parents: [Int?] = []
        var matches: [Bool] = []
        let needle = String(query.unicodeScalars.prefix(256))
        let searching = !needle.isEmpty
        let scanBudget = 2_000
        let budget = max(1, min(maxRows, 200)), depthBudget = max(0, min(maxDepth, 12))
        func children(_ value: EntitlementValue?) -> Bool {
            switch value {
            case .array(let a): return !a.isEmpty
            case .dictionary(let d): return !d.entries.isEmpty
            default: return false
            }
        }
        func visit(_ old: EntitlementValue?, _ new: EntitlementValue?, _ path: String, _ label: String, _ depth: Int,
                   parent: Int? = nil, inheritedMatch: Bool = false, rawLabel: String? = nil) {
            guard visited < scanBudget else { hitLimit = true; return }
            visited += 1
            if changesOnly && old == nil && new == nil { return }
            let kind: ChangeKind? = changesOnly
                ? (old == nil ? .added : new == nil ? .removed : old == new ? .unchanged : .changed)
                : nil
            if kind == .unchanged { return }
            let matched = inheritedMatch || !searching || ((rawLabel ?? label).localizedStandardContains(needle) ||
                (parent.map { result[$0].displayPath + " / " + label } ?? label).localizedStandardContains(needle))
            let index = result.count
            parents.append(parent)
            matches.append(matched)
            let hasChildren = children(old) || children(new)
            let displayPath = parent.map { result[$0].displayPath + " / " + label } ?? label
            result.append(.init(id: path, depth: depth, label: label, displayPath: displayPath, previous: old, current: new,
                                expandable: hasChildren && depth < depthBudget, cachedKind: kind))
            guard hasChildren else { return }
            guard depth < depthBudget else { hitLimit = true; return }
            guard searching || expanded.contains(path) else { return }
            // Different container types are separate branches, avoiding invented key/index correspondence.
            switch (old, new) {
            case (.dictionary(let a), .dictionary(let b)):
                dictionaries(a.entries, b.entries, path, depth, index, matched)
            case (.array(let a), .array(let b)):
                arrays(a, b, path, depth, index, matched)
            case (.dictionary(let a), .none): dictionaries(a.entries, [], path, depth, index, matched)
            case (.none, .dictionary(let b)): dictionaries([], b.entries, path, depth, index, matched)
            case (.array(let a), .none): arrays(a, [], path, depth, index, matched)
            case (.none, .array(let b)): arrays([], b, path, depth, index, matched)
            default:
                if children(old) { visit(old, nil, path + "/previous", "Previous structure", depth + 1, parent: index, inheritedMatch: matched) }
                if children(new) { visit(nil, new, path + "/current", "Current structure", depth + 1, parent: index, inheritedMatch: matched) }
            }
        }
        func arrays(_ a: [EntitlementValue], _ b: [EntitlementValue], _ path: String, _ depth: Int, _ parent: Int, _ matched: Bool) {
            for i in 0..<max(a.count, b.count) {
                guard visited < scanBudget else { hitLimit = true; break }
                visit(i < a.count ? a[i] : nil, i < b.count ? b[i] : nil, path + "/i\(i)", "[\(i)]", depth + 1, parent: parent, inheritedMatch: matched)
            }
        }
        func dictionaries(_ a: [EntitlementEntry], _ b: [EntitlementEntry], _ path: String, _ depth: Int, _ parent: Int, _ matched: Bool) {
            var i = 0, j = 0
            while i < a.count || j < b.count {
                guard visited < scanBudget else { hitLimit = true; break }
                let key: String, old: EntitlementValue?, new: EntitlementValue?
                if i == a.count { key = b[j].key; old = nil; new = b[j].value; j += 1 }
                else if j == b.count { key = a[i].key; old = a[i].value; new = nil; i += 1 }
                else if a[i].key.utf8.elementsEqual(b[j].key.utf8) {
                    key = a[i].key; old = a[i].value; new = b[j].value; i += 1; j += 1
                } else if a[i].key.utf8.lexicographicallyPrecedes(b[j].key.utf8) {
                    key = a[i].key; old = a[i].value; new = nil; i += 1
                } else { key = b[j].key; old = nil; new = b[j].value; j += 1 }
                visit(old, new, path + "/k" + Data(key.utf8).base64EncodedString(),
                      EntitlementValue.string(key).preview(maxCharacters: 256), depth + 1,
                      parent: parent, inheritedMatch: matched, rawLabel: key)
            }
        }
        visit(previous, current, "root", "Value", 0)
        // Keep ancestry for matching descendants; identities never depend on display text.
        if searching {
            for i in result.indices.reversed() where matches[i] {
                if let parent = parents[i] { matches[parent] = true }
            }
        }
        let filtered = result.enumerated().compactMap { matches[$0.offset] ? $0.element : nil }
        matchingRowCount = filtered.count
        let requested = max(0, min(offset, scanBudget - 1))
        let lastPage = filtered.isEmpty ? 0 : ((filtered.count - 1) / budget) * budget
        pageOffset = min((requested / budget) * budget, lastPage)
        rows = filtered.dropFirst(pageOffset).prefix(budget).map { $0.classified() }
        hasNextPage = pageOffset + rows.count < filtered.count
        searchIncomplete = hitLimit
        limited = hitLimit || hasNextPage
    }
}

extension EntitlementChange {
    /// Complete selected values, independent of inspector display limits or browser filters.
    public func selectedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
