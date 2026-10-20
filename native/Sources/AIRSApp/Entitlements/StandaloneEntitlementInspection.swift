import Foundation
import EntitlementDiffCore
import EntitlementDiffModel

/// A session projection of one real captured input. It is not an exchange document
/// or a comparison against an invented baseline.
struct StandaloneEntitlementInspection: Identifiable, Sendable {
    let side: ComparisonSide
    let snapshot: EntitlementSnapshot
    let revision: UUID
    let entries: [StandaloneEntitlementEntry]
    var id: String { revision.uuidString + ":" + side.rawValue }

    init(side: ComparisonSide, snapshot: EntitlementSnapshot, revision: UUID) {
        self.side = side
        self.snapshot = snapshot
        self.revision = revision
        entries = snapshot.entitlements.entries.map {
            StandaloneEntitlementEntry(key: $0.key, value: $0.value)
        }
    }

    func entry(forExactKey key: String) -> StandaloneEntitlementEntry? {
        entries.first { $0.key.utf8.elementsEqual(key.utf8) }
    }

    var emptyMessage: String {
        snapshot.presence == .notPresent
            ? "No entitlement dictionary was present in this captured input."
            : "The captured entitlement dictionary is present and empty."
    }
}

struct StandaloneEntitlementEntry: Identifiable, Sendable {
    let key: String
    let value: EntitlementValue
    /// Keep byte-distinct keys separate even when Swift String considers them equivalent.
    var id: String { Data(key.utf8).base64EncodedString() }
    var keyPreview: String { EntitlementValue.string(key).preview(maxCharacters: 512) }
    var typeName: String { value.typeName }
    var valuePreview: String { value.preview(maxCharacters: 160) }
}

/// Local presentation state. Replacing a captured input invalidates navigation,
/// including when the replacement happens to contain the same entitlement keys.
struct StandaloneEntitlementBrowser {
    private(set) var input: StandaloneEntitlementInspection
    var query = "" {
        didSet {
            if !visibleEntries.contains(where: { $0.id == selection }) { selection = nil }
        }
    }
    var selection: String?

    init(input: StandaloneEntitlementInspection) {
        self.input = input
        selection = input.entries.first?.id
    }

    var visibleEntries: [StandaloneEntitlementEntry] {
        guard !query.isEmpty else { return input.entries }
        return input.entries.filter { $0.key.localizedStandardContains(query) }
    }

    var selectedEntry: StandaloneEntitlementEntry? {
        guard let selection else { return nil }
        return visibleEntries.first { $0.id == selection }
    }

    mutating func replaceInput(_ input: StandaloneEntitlementInspection) {
        guard self.input.id != input.id else { return }
        self = Self(input: input)
    }
}

struct StandaloneValueRow: Identifiable, Sendable {
    let id: String
    let label: String
    let displayPath: String
    let value: EntitlementValue
    var isContainer: Bool {
        switch value { case .array, .dictionary: true; default: false }
    }
    var leaf: InspectorLeaf? { InspectorLeaf(value) }
}

/// Reuses the existing bounded immediate-child traversal without classifying
/// rows, fabricating a second snapshot, or evaluating equality with an empty value.
/// Only the captured source side is projected into this single-value interface.
struct StandaloneValueNavigator {
    private let side: ComparisonSide
    private var navigator: InspectorBranchNavigator

    init(value: EntitlementValue, side: ComparisonSide) {
        self.side = side
        navigator = InspectorBranchNavigator(
            previous: side == .previous ? value : nil,
            current: side == .current ? value : nil)
    }

    var root: StandaloneValueRow { project(navigator.root) }
    var rows: [StandaloneValueRow] { navigator.rows.map(project) }
    var exactChild: StandaloneValueRow? { navigator.exactChild.map(project) }
    var depth: Int { navigator.depth }
    var offset: Int { navigator.offset }
    var canGoBack: Bool { navigator.canGoBack }
    var hasPrevious: Bool { navigator.hasPrevious }
    var hasNext: Bool { navigator.hasNext }
    var arrayCount: Int? { navigator.arrayCount }
    var canFindChildKey: Bool { navigator.canFindChildKey }

    mutating func nextPage() { navigator.nextPage() }
    mutating func previousPage() { navigator.previousPage() }
    mutating func firstPage() { navigator.firstPage() }
    mutating func back() { navigator.back() }
    mutating func goToRoot() {
        if let root = navigator.rootAncestor { _ = navigator.jump(to: root) }
    }
    @discardableResult mutating func enter(_ id: String) -> Bool { navigator.enter(id) }
    @discardableResult mutating func goToArrayIndex(_ index: Int) -> Bool { navigator.goToArrayIndex(index) }
    @discardableResult mutating func findExactChild(_ key: String) -> Bool { navigator.findExactChild(key) }
    mutating func clearExactChild() { navigator.clearExactChild() }

    private func project(_ row: InspectorRow) -> StandaloneValueRow {
        // The navigator is initialized with exactly one nonnil side and never
        // creates children on the other side, so the selected value must exist.
        guard let value = side == .previous ? row.previous : row.current else {
            preconditionFailure("Standalone branch lost its captured source value")
        }
        return .init(id: row.id, label: row.label, displayPath: row.displayPath, value: value)
    }
}
