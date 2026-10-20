import Foundation
import CryptoKit

public struct ExactUTF8Key: Hashable, Codable, Sendable {
    public let bytes: Data
    public init(_ value: String) { bytes = Data(value.utf8) }
}
public enum ComponentRelation: String, Codable, Sendable, Hashable {
    case sameLocation, uniqueIdentifierCandidate, addedWithinScope, removedWithinScope, ambiguous, unobservedInOtherScope
}
public struct ComponentMatch: Codable, Sendable, Identifiable {
    public let id: UUID
    public let previousID: UUID?
    public let currentID: UUID?
    public let relation: ComponentRelation
    public let reasons: [String]
    public init(id: UUID, previousID: UUID?, currentID: UUID?, relation: ComponentRelation, reasons: [String]) {
        self.id = id; self.previousID = previousID; self.currentID = currentID; self.relation = relation; self.reasons = reasons
    }
}
public struct ComponentMatchResult: Codable, Sendable {
    public let matches: [ComponentMatch]
    public let previousScope: InventoryScope
    public let currentScope: InventoryScope
    public init(matches: [ComponentMatch], previousScope: InventoryScope, currentScope: InventoryScope) {
        self.matches = matches; self.previousScope = previousScope; self.currentScope = currentScope
    }
}
public enum ComponentMatcher {
    private struct Identity: Hashable { let kind: ExactUTF8Key; let label: ExactUTF8Key }
    public static func match(previous: ComponentInventory, current: ComponentInventory) throws -> ComponentMatchResult {
        try previous.validate(); try current.validate()
        var old = Set(previous.components.map(\.id)), new = Set(current.components.map(\.id)), matches: [ComponentMatch] = []
        func append(_ a: ComponentRecord?, _ b: ComponentRecord?, _ relation: ComponentRelation, _ reasons: [String]) throws {
            let fields = ["airs.component.match.v1", previous.id.uuidString, current.id.uuidString, a?.id.uuidString ?? "", b?.id.uuidString ?? "", relation.rawValue]
            let digest = Array(SHA256.hash(data: try JSONEncoder().encode(fields)).prefix(16))
            let id = UUID(uuid: (digest[0],digest[1],digest[2],digest[3],digest[4],digest[5],digest[6],digest[7],digest[8],digest[9],digest[10],digest[11],digest[12],digest[13],digest[14],digest[15]))
            matches.append(.init(id: id, previousID: a?.id, currentID: b?.id, relation: relation, reasons: reasons))
            if let a { old.remove(a.id) }; if let b { new.remove(b.id) }
        }
        let byPath = Dictionary(uniqueKeysWithValues: current.components.map { (ExactUTF8Key($0.relativePath), $0) })
        for a in previous.components {
            if let b = byPath[ExactUTF8Key(a.relativePath)] {
                var reasons = ["Exact UTF-8 code location correspondence; not cryptographic identity."]
                if a.declaredBundleID.map(ExactUTF8Key.init) != b.declaredBundleID.map(ExactUTF8Key.init) { reasons.append("Declared identifier changed or became unavailable.") }
                if !a.kind.utf8.elementsEqual(b.kind.utf8) { reasons.append("Observed component kind changed.") }
                try append(a, b, .sameLocation, reasons)
            }
        }
        func identity(_ r: ComponentRecord) -> Identity? {
            r.declaredBundleID.map { Identity(kind: .init(r.kind), label: .init($0)) }
        }
        func grouped(_ records: [ComponentRecord]) -> [Identity: [ComponentRecord]] {
            var values: [Identity: [ComponentRecord]] = [:]
            for record in records { if let key = identity(record) { values[key, default: []].append(record) } }
            return values
        }
        let oldIDs = grouped(previous.components), newIDs = grouped(current.components)
        for a in previous.components where old.contains(a.id) {
            if let key = identity(a), let others = newIDs[key], !others.isEmpty {
                if oldIDs[key]?.count == 1, others.count == 1, let b = others.first, new.contains(b.id) {
                    try append(a, b, .uniqueIdentifierCandidate, ["Unique same-kind declared identifier suggests a move; not accepted as identity or authorized for comparison."])
                } else { try append(a, nil, .ambiguous, ["Duplicate or already-corresponding declared identifiers cannot establish a move."]) }
            } else {
                let covered = covers(current.scope, path: a.relativePath)
                try append(a, nil, covered ? .removedWithinScope : .unobservedInOtherScope,
                    [covered ? "Not observed in the other's complete recorded search scope." : "Other scope is incomplete, excluded or did not cover this location; removal is unproven."])
            }
        }
        for b in current.components where new.contains(b.id) {
            if let key = identity(b), oldIDs[key] != nil {
                try append(nil, b, .ambiguous, ["Declared identifier does not provide a unique unmatched correspondence."])
            } else {
                let covered = covers(previous.scope, path: b.relativePath)
                try append(nil, b, covered ? .addedWithinScope : .unobservedInOtherScope,
                    [covered ? "Not observed in the other's complete recorded search scope." : "Other scope is incomplete, excluded or did not cover this location; addition is unproven."])
            }
        }
        return .init(matches: matches, previousScope: previous.scope, currentScope: current.scope)
    }
    private static func covers(_ scope: InventoryScope, path: String) -> Bool {
        // Exclusions are legacy human-readable strings, not exact range records.
        // Conservatively decline absence claims instead of guessing their ranges.
        guard scope.completion == .completeWithinScope, scope.issues.isEmpty, scope.exclusions.isEmpty else { return false }
        return scope.searchedLocations.contains { path.utf8.starts(with: ($0 + "/").utf8) }
    }
}
