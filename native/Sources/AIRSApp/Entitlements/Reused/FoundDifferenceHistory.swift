/// Session-only positions; never stores source values or comparison cursors.
struct FoundDifferenceHistory<Position: Sendable>: Sendable {
    static var limit: Int { 64 }
    struct Entry: Sendable {
        let ordinal: Int
        let position: Position
    }
    private(set) var entries: [Entry] = []
    private(set) var index = 0
    var canPrevious: Bool { index > 0 }
    var canNext: Bool { index + 1 < entries.count }
    var isAtFrontier: Bool { !canNext }
    var rangeLabel: String? {
        guard let first = entries.first, let last = entries.last else { return nil }
        return "Found differences \(first.ordinal)–\(last.ordinal)"
    }
    var validRange: String? {
        guard let first = entries.first, let last = entries.last else { return nil }
        return "\(first.ordinal) through \(last.ordinal)"
    }
    mutating func select(input: String) -> Entry? {
        // Bound parsing before converting; no scan of arbitrary pasted input.
        let bytes = Array(input.utf8.prefix(21))
        guard !bytes.isEmpty, bytes.count <= 20, bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let ordinal = Int(input), let first = entries.first, let last = entries.last,
              ordinal >= first.ordinal, ordinal <= last.ordinal else { return nil }
        index = ordinal - first.ordinal
        return entries[index]
    }
    var notice: String? {
        guard let first = entries.first, first.ordinal > 1 else { return nil }
        return "Found history starts at difference \(first.ordinal). Find First Difference to restart."
    }
    mutating func append(_ position: Position) -> Entry {
        let entry = Entry(ordinal: (entries.last?.ordinal ?? 0) + 1, position: position)
        if entries.count == Self.limit { entries.removeFirst() }
        entries.append(entry); index = entries.count - 1
        return entry
    }
    mutating func previous() -> Entry? {
        guard canPrevious else { return nil }
        index -= 1; return entries[index]
    }
    mutating func next() -> Entry? {
        guard canNext else { return nil }
        index += 1; return entries[index]
    }
}
