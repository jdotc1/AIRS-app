import Foundation
import AIRSCore
import EntitlementDiffCore

public enum DeclarationCategory: String, Codable, Sendable, CaseIterable { case info, loadCommands, privacy }
public enum DeclarationState: String, Codable, Sendable { case present, notPresent, unavailable }
public struct DeclarationObservation: Codable, Sendable {
    public let componentID: UUID
    public let category: DeclarationCategory
    public let architecture: String?
    public let relativeSource: String
    public let state: DeclarationState
    public let bytes: Data?
    public let issue: String?
    public init(componentID: UUID, category: DeclarationCategory, architecture: String? = nil, relativeSource: String,
                state: DeclarationState, bytes: Data? = nil, issue: String? = nil) {
        self.componentID = componentID; self.category = category; self.architecture = architecture
        self.relativeSource = relativeSource; self.state = state; self.bytes = bytes; self.issue = issue
    }
    public static let infoKeys = ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "CFBundlePackageType", "LSMinimumSystemVersion", "CFBundleSupportedPlatforms"]
    public func values() throws -> EntitlementDictionary {
        guard state == .present, let bytes, bytes.count <= 65_536,
              let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { throw InspectionArchiveError.invalid }
        let selected = category == .info ? object.filter { Self.infoKeys.contains($0.key) } : object
        return try FoundationEntitlementDecoder(limits: .init(maxDepth: 32, maxNodes: 10_000, maxBytes: 65_536)).decode(selected)
    }
    func validate(record: ComponentRecord, requested: Architecture) throws {
        let parts = relativeSource.split(separator: "/", omittingEmptySubsequences: false)
        guard relativeSource.utf8.count <= 4096, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }),
              (issue?.utf8.count ?? 0) <= 4096,
              category == .loadCommands ? architecture == requested.rawValue : architecture == nil else { throw InspectionArchiveError.invalid }
        if state == .present {
            if category == .loadCommands { guard record.architectures.contains(requested.rawValue) else { throw InspectionArchiveError.invalid } }
            _ = try values()
        } else {
            guard bytes == nil, state != .notPresent || category == .privacy else { throw InspectionArchiveError.invalid }
        }
    }
}
public enum ComponentEntitlementResult: Sendable {
    case compared(matchID: UUID, architecture: Architecture, report: EntitlementDiffCore.ComparisonReport)
    case unavailable(matchID: UUID, architecture: Architecture, reason: String)
    public var matchID: UUID { switch self { case .compared(let id,_,_), .unavailable(let id,_,_): id } }
    public var architecture: Architecture { switch self { case .compared(_,let a,_), .unavailable(_,let a,_): a } }
}
public struct DeclarationDifference: Sendable {
    public let category: DeclarationCategory
    public let comparison: EntitlementComparison?
    public let message: String
}
public struct ComponentReview: Sendable {
    public let previous: ComponentInventory
    public let current: ComponentInventory
    public let matching: ComponentMatchResult
    public let architecture: Architecture
    public let entitlementResults: [ComponentEntitlementResult]
    public let previousDeclarations: [DeclarationObservation]
    public let currentDeclarations: [DeclarationObservation]
    public init(previous: ComponentInventory, current: ComponentInventory, matching: ComponentMatchResult, architecture: Architecture,
                entitlementResults: [ComponentEntitlementResult], previousDeclarations: [DeclarationObservation], currentDeclarations: [DeclarationObservation]) {
        self.previous = previous; self.current = current; self.matching = matching; self.architecture = architecture
        self.entitlementResults = entitlementResults; self.previousDeclarations = previousDeclarations; self.currentDeclarations = currentDeclarations
    }
    public func declarations(for match: ComponentMatch) throws -> [DeclarationDifference] {
        try DeclarationCategory.allCases.map { category in
            guard match.relation == .sameLocation,
                  let a = previousDeclarations.first(where: { $0.componentID == match.previousID && $0.category == category }),
                  let b = currentDeclarations.first(where: { $0.componentID == match.currentID && $0.category == category }),
                  a.state != .unavailable, b.state != .unavailable else {
                let reasons = [("Previous", previousDeclarations, match.previousID), ("Current", currentDeclarations, match.currentID)].compactMap { side, observations, id -> String? in
                    guard let item = observations.first(where: { $0.componentID == id && $0.category == category }) else { return nil }
                    return side + " (" + item.relativeSource + "): " + (item.issue ?? item.state.rawValue)
                }
                return .init(category: category, comparison: nil, message: (["Unavailable or not captured at an accepted exact location."] + reasons).joined(separator: "\n"))
            }
            let before = a.state == .notPresent ? EntitlementDictionary() : try a.values()
            let after = b.state == .notPresent ? EntitlementDictionary() : try b.values()
            return .init(category: category, comparison: .init(previous: before, current: after),
                message: category == .privacy ? "Explicit manifest paths only; absence is not a compliance defect." : "Typed declarations at the recorded component/slice and source paths.")
        }
    }
}
public enum ComponentComparison {
    /// Schema-safe display name; archive match references bind this ID to its exact UTF-8 path.
    public static func sourceName(componentID: UUID) -> String { "component-" + componentID.uuidString }
    public static func review(previous: ComponentInventory, current: ComponentInventory, architecture: Architecture,
        entitlementResults: [ComponentEntitlementResult], previousDeclarations: [DeclarationObservation] = [], currentDeclarations: [DeclarationObservation] = []) throws -> ComponentReview {
        let matching = try ComponentMatcher.match(previous: previous, current: current)
        guard entitlementResults.count <= matching.matches.count, Set(entitlementResults.map(\.matchID)).count == entitlementResults.count else { throw InspectionArchiveError.invalid }
        for outcome in entitlementResults {
            guard outcome.architecture == architecture, let match = matching.matches.first(where: { $0.id == outcome.matchID }) else { throw InspectionArchiveError.invalid }
            switch outcome {
            case .compared(_,_,let report):
                guard match.relation == .sameLocation,
                      let a = previous.components.first(where: { $0.id == match.previousID }), let b = current.components.first(where: { $0.id == match.currentID }),
                      a.architectures.contains(architecture.rawValue), b.architectures.contains(architecture.rawValue),
                      report.previous.architecture == architecture, report.current.architecture == architecture,
                      report.previous.sourceName == sourceName(componentID: a.id), report.current.sourceName == sourceName(componentID: b.id) else { throw InspectionArchiveError.invalid }
            case .unavailable(_,_,let reason): guard !reason.isEmpty, reason.utf8.count <= 4096 else { throw InspectionArchiveError.invalid }
            }
        }
        for (inventory, observations) in [(previous, previousDeclarations), (current, currentDeclarations)] {
            guard observations.count <= 384 else { throw InspectionArchiveError.limit }
            var seen = Set<String>()
            for item in observations {
                guard let record = inventory.components.first(where: { $0.id == item.componentID }),
                      seen.insert(item.componentID.uuidString + ":" + item.category.rawValue).inserted else { throw InspectionArchiveError.invalid }
                try item.validate(record: record, requested: architecture)
            }
        }
        let complete = matching.matches.map { match in
            entitlementResults.first(where: { $0.matchID == match.id }) ?? .unavailable(matchID: match.id, architecture: architecture,
                reason: match.relation == .sameLocation ? "Not requested; no live read is implied." : "No accepted exact-location pair; no entitlement agreement is inferred.")
        }
        return .init(previous: previous, current: current, matching: matching, architecture: architecture, entitlementResults: complete,
            previousDeclarations: previousDeclarations, currentDeclarations: currentDeclarations)
    }
}
