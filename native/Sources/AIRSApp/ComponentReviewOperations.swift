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
enum ComponentReviewOperations {
    static func build(_ previous: URL, _ current: URL, _ architecture: Architecture) throws -> ComponentReviewSession {
        let a = try ComponentInventoryBuilder().capture(previous), b = try ComponentInventoryBuilder().capture(current)
        func declarations(_ capture: LiveComponentInventory) throws -> [DeclarationObservation] {
            var values: [DeclarationObservation] = [], budget = 1_048_576
            for record in capture.inventory.components {
                try Task.checkCancellation()
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
        guard let live = session.live, live.count == 2,
              let match = session.review.matching.matches.first(where:{$0.id == matchID}), match.relation == .sameLocation,
              let previousID = match.previousID, let currentID = match.currentID,
              let a = live[0].units[previousID], let b = live[1].units[currentID] else { throw InspectionArchiveError.invalid }
        var before: EntitlementSnapshot?, after: EntitlementSnapshot?, issues: [String] = []
        for (index,unit) in [a,b].enumerated() {
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
