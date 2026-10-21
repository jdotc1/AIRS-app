import Foundation
import AIRSCore
import AIRSEntitlements
import EntitlementDiffCore

struct ComponentReviewSession: Identifiable, Sendable {
    let id = UUID()
    let review: ComponentReview
    let archiveBytes: Data
    let sourceURLs: [URL]
    let live: [LiveComponentInventory]?
    let differences: [UUID: [DeclarationDifference]]
    init(review: ComponentReview, archiveBytes: Data, sourceURLs: [URL], live: [LiveComponentInventory]?) throws {
        self.review = review; self.archiveBytes = archiveBytes; self.sourceURLs = sourceURLs; self.live = live
        differences = try Dictionary(uniqueKeysWithValues: review.matching.matches.map { ($0.id, try review.declarations(for:$0)) })
    }
}
struct ComponentReadAvailability: Sendable {
    let available: Bool
    let reason: String
    fileprivate var pair: ComponentReadPair? = nil
}
fileprivate struct ComponentReadPair: Sendable {
    let previousID: UUID
    let currentID: UUID
    let previous: BundleImageProvenance
    let current: BundleImageProvenance
}
enum ComponentReviewOperations {
    /// Captured applicability only. The reader still validates live identity and freshness.
    static func readAvailability(_ session: ComponentReviewSession, matchID: UUID, busy: Bool = false) -> ComponentReadAvailability {
        guard let live = session.live else {
            return .init(available:false,reason:"Imported evidence cannot authorize live entitlement reads.")
        }
        guard live.count == 2 else {
            return .init(available:false,reason:"Both live component inventories are required.")
        }
        guard let match = session.review.matching.matches.first(where: { $0.id == matchID }) else {
            return .init(available:false,reason:"The component match is no longer in this review.")
        }
        guard match.relation == .sameLocation else {
            return .init(available:false,reason:"Entitlement reads require an exact-location component pair.")
        }
        guard let previousID = match.previousID, let currentID = match.currentID else {
            return .init(available:false,reason:"Both matched component identities are required.")
        }
        guard let a = live[0].units[previousID], let b = live[1].units[currentID] else {
            return .init(available:false,reason:"Both components require a live discovered file capability; rebuild the review.")
        }
        let pair = ComponentReadPair(previousID:previousID,currentID:currentID,previous:a,current:b)
        let architecture = session.review.architecture.rawValue
        for (side, inventory, id) in [("Previous",session.review.previous,previousID),("Current",session.review.current,currentID)] {
            guard let record = inventory.components.first(where: { $0.id == id }), record.architectures.contains(architecture) else {
                return .init(available:false,reason:side + " component has no discovered " + architecture + " slice; rebuild the review if the selection changed.",pair:pair)
            }
        }
        guard !busy else { return .init(available:false,reason:"Wait for the current operation to finish.") }
        return .init(available:true,reason:"Ready to request " + architecture + "; live files will be checked again during the read.",pair:pair)
    }
    static func build(_ previous: URL, _ current: URL, _ architecture: Architecture) throws -> ComponentReviewSession {
        let a = try ComponentInventoryBuilder().capture(previous), b = try ComponentInventoryBuilder().capture(current)
        func declarations(_ capture: LiveComponentInventory) throws -> [DeclarationObservation] {
            var values: [DeclarationObservation] = [], budget = 1_048_576
            for record in capture.inventory.components {
                try Task.checkCancellation()
                if let root = capture.resourceDeclarations, root.componentID == record.id {
                    func observation(_ category: DeclarationCategory, _ source: String, _ bytes: Data?, _ issue: String? = nil) -> DeclarationObservation {
                        let value = DeclarationObservation(componentID: record.id, category: category, relativeSource: source,
                            state: issue != nil ? .unavailable : (bytes == nil ? .notPresent : .present), bytes: bytes, issue: issue)
                        do { if value.state == .present { _ = try value.values() }; return value }
                        catch { return .init(componentID: record.id, category: category, relativeSource: source, state: .unavailable, issue: error.localizedDescription) }
                    }
                    values.append(observation(.info, "Contents/Info.plist", root.bytes.info))
                    values.append(observation(.privacy, "Contents/Resources/PrivacyInfo.xcprivacy", root.bytes.privacy, root.bytes.privacyIssue))
                    values.append(.init(componentID: record.id, category: .loadCommands, architecture: architecture.rawValue,
                        relativeSource: "Contents/Info.plist", state: .unavailable, issue: "Principal executable unresolved; declaration observation has no image capability."))
                    continue
                }
                guard let unit = capture.units[record.id] else {
                    values += DeclarationCategory.allCases.map { .init(componentID:record.id,category:$0,architecture:$0 == .loadCommands ? architecture.rawValue : nil,
                        relativeSource:record.relativePath,state:.unavailable,issue:"No current discovered file capability.") }
                    continue
                }
                values.append(ComponentInfoDeclarations.capture(unit,componentID:record.id))
                values.append(ComponentLoaderDeclarations.capture(unit,componentID:record.id,architecture:architecture.rawValue,budget:&budget))
                values.append(ComponentPrivacyDeclarations.capture(unit,componentID:record.id))
            }
            return values
        }
        let review = try ComponentComparison.review(previous:a.inventory,current:b.inventory,architecture:architecture,entitlementResults:[],
            previousDeclarations:declarations(a),currentDeclarations:declarations(b))
        return try .init(review:review,archiveBytes:ComponentReviewArchive.encode(review),sourceURLs:[previous,current],live:[a,b])
    }
    static func read(_ session: ComponentReviewSession, matchID: UUID,
                     reader: any CodeUnitSnapshotReading = CodeUnitEntitlementReader()) async throws -> ComponentReviewSession {
        try Task.checkCancellation()
        let availability = readAvailability(session,matchID:matchID)
        guard let pair = availability.pair, let live = session.live else { throw ReportError.invalidContents(availability.reason) }
        let previousID = pair.previousID, currentID = pair.currentID
        let a = pair.previous, b = pair.current
        var before: EntitlementSnapshot?, after: EntitlementSnapshot?, issues: [String] = []
        if !availability.available { issues.append(availability.reason) }
        for (index,unit) in (availability.available ? [a,b] : []).enumerated() {
            try Task.checkCancellation()
            do {
                let componentID = index == 0 ? previousID : currentID
                let observations = index == 0 ? session.review.previousDeclarations : session.review.currentDeclarations
                guard let captured = observations.first(where: { $0.componentID == componentID && $0.category == .info }),
                      captured.state == .present, let bytes = captured.bytes,
                      try CodeUnitPreflight.inspect(unit).infoBytes == bytes else {
                    throw ReportError.invalidContents("Component metadata changed or was unavailable; rebuild the component review.")
                }
                let value = try await reader.read(unit:unit,architecture:session.review.architecture)
                guard try CodeUnitPreflight.inspect(unit).infoBytes == bytes else {
                    throw ReportError.invalidContents("Component metadata changed; rebuild the component review.")
                }
                let bound = EntitlementSnapshot(sourceName:ComponentComparison.sourceName(componentID:componentID),
                    signingIdentifier:value.signingIdentifier,architecture:value.architecture,presence:value.presence,
                    origin:value.origin,entitlements:value.entitlements,identity:value.identity)
                if index == 0 { before = bound } else { after = bound }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                issues.append((index == 0 ? "Previous: " : "Current: ") + error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        let outcome: ComponentEntitlementResult
        if let before, let after {
            outcome = .compared(matchID:matchID,architecture:session.review.architecture,report:try .init(previous:before,current:after))
        } else { outcome = .unavailable(matchID:matchID,architecture:session.review.architecture,reason:issues.joined(separator:"\n")) }
        let old = session.review
        let review = try ComponentComparison.review(previous:old.previous,current:old.current,architecture:old.architecture,
            entitlementResults:old.entitlementResults.filter{$0.matchID != matchID} + [outcome],previousDeclarations:old.previousDeclarations,currentDeclarations:old.currentDeclarations)
        return try .init(review:review,archiveBytes:ComponentReviewArchive.encode(review),sourceURLs:session.sourceURLs,live:live)
    }
}
