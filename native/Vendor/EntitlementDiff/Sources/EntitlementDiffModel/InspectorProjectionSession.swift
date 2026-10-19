import Foundation
import EntitlementDiffCore

/// One selected entitlement in one comparison revision. Presentation only, never serialized.
/// Values are captured once; the owner replaces this session when source identity changes.
public struct InspectorProjectionSession {
    public let comparisonRevision: UUID
    public let selectionID: String
    private let previous: EntitlementValue?
    private let current: EntitlementValue?
    public private(set) var query = ""
    public private(set) var changesOnly = false
    public private(set) var expanded: Set<String> = ["root"]
    public private(set) var projection: ValueInspector
    /// Identity changes only when a new projection is constructed.
    public private(set) var projectionRevision = UUID()

    public init(change: EntitlementChange, comparisonRevision: UUID) {
        self.comparisonRevision = comparisonRevision
        selectionID = change.id
        previous = change.previous; current = change.current
        projection = ValueInspector(previous: change.previous, current: change.current,
                                    expanded: ["root"], maxRows: 50)
    }

    public mutating func setQuery(_ value: String) {
        let bounded = String(value.unicodeScalars.prefix(256))
        guard !bounded.utf8.elementsEqual(query.utf8) else { return }
        query = bounded
        refresh(offset: 0)
    }
    public mutating func setChangesOnly(_ value: Bool) {
        guard value != changesOnly else { return }
        changesOnly = value
        refresh(offset: 0)
    }
    public mutating func toggleExpansion(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        refresh(offset: 0)
    }
    public mutating func collapse() {
        guard !expanded.isEmpty || !query.isEmpty || projection.pageOffset != 0 else { return }
        expanded = []; query = ""
        refresh(offset: 0)
    }
    public mutating func nextPage() {
        guard projection.hasNextPage else { return }
        refresh(offset: projection.pageOffset + 50)
    }
    public mutating func previousPage() {
        guard projection.pageOffset > 0 else { return }
        refresh(offset: projection.pageOffset - 50)
    }
    private mutating func refresh(offset: Int) {
        projection = ValueInspector(previous: previous, current: current, expanded: expanded,
                                    maxRows: 50, query: query, changesOnly: changesOnly, offset: offset)
        projectionRevision = UUID()
    }
}
