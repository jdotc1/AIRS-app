import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements
final class ComponentReviewTests: XCTestCase {
    func inventory(_ identifier: String = "example") -> ComponentInventory {
        .init(scope: .init(searchedLocations: ["Contents/MacOS"], completion: .completeWithinScope, exclusions: [], issues: []), components: [
            .init(relativePath: "Contents/MacOS/Main", kind: "app", declaredBundleID: identifier, architectures: ["arm64"])])
    }
    func testResultsRequireKnownMatchSliceAndSourceBinding() throws {
        let a = inventory(), b = inventory(), matching = try ComponentMatcher.match(previous: a, current: b)
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let report = try ComparisonReport(previous: pair.previous, current: pair.current)
        XCTAssertThrowsError(try ComponentComparison.review(previous: a, current: b, architecture: .arm64,
            entitlementResults: [.compared(matchID: UUID(), architecture: .arm64, report: report)]))
        XCTAssertThrowsError(try ComponentComparison.review(previous: a, current: b, architecture: .arm64,
            entitlementResults: [.compared(matchID: matching.matches[0].id, architecture: .arm64, report: report)]))
        let review = try ComponentComparison.review(previous: a, current: b, architecture: .arm64, entitlementResults: [])
        XCTAssertEqual(review.entitlementResults.count, 1)
        guard case .unavailable = review.entitlementResults[0] else { return XCTFail("Not requested is unavailable") }
    }
    func testDeclarationTypesMissingPrivacyAndUnavailableStayDistinct() throws {
        let a = inventory(), b = inventory()
        func observation(_ id: UUID, value: Any) throws -> DeclarationObservation {
            .init(componentID: id, category: .info, relativeSource: "Contents/Info.plist", state: .present,
                bytes: try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion":value,"ignored":"not compared"], format: .binary, options: 0))
        }
        let review = try ComponentComparison.review(previous: a, current: b, architecture: .arm64, entitlementResults: [],
            previousDeclarations: [try observation(a.components[0].id, value: true), .init(componentID:a.components[0].id,category:.privacy,relativeSource:"Contents/Resources/PrivacyInfo.xcprivacy",state:.notPresent)],
            currentDeclarations: [try observation(b.components[0].id, value: 1), .init(componentID:b.components[0].id,category:.privacy,relativeSource:"Contents/Resources/PrivacyInfo.xcprivacy",state:.notPresent)])
        let differences = try review.declarations(for: review.matching.matches[0])
        XCTAssertEqual(differences.first { $0.category == .info }?.comparison?.changes.count, 1)
        XCTAssertEqual(differences.first { $0.category == .privacy }?.comparison?.changes.count, 0)
        XCTAssertNil(differences.first { $0.category == .loadCommands }?.comparison)
    }
    func testComparedPayloadBytesRoundTripAndUnavailableSourcesRemainVisible() throws {
        let a = inventory(), b = inventory(), match = try ComponentMatcher.match(previous:a,current:b).matches[0]
        func snapshot(_ value: Bool, _ id: UUID) -> EntitlementSnapshot { .init(sourceName:ComponentComparison.sourceName(componentID:id),signingIdentifier:"example",architecture:.arm64,presence:.dictionaryPresent,entitlements:.init(["owned":.boolean(value)])) }
        let report = try ComparisonReport(previous:snapshot(false,a.components[0].id),current:snapshot(true,b.components[0].id))
        let observations = [DeclarationObservation(componentID:a.components[0].id,category:.loadCommands,architecture:"arm64",relativeSource:"Contents/MacOS/Main",state:.unavailable,issue:"Requested slice is missing")]
        let review = try ComponentComparison.review(previous:a,current:b,architecture:.arm64,entitlementResults:[.compared(matchID:match.id,architecture:.arm64,report:report)],previousDeclarations:observations)
        let archive = try InspectionArchive.decode(ComponentReviewArchive.encode(review))
        XCTAssertEqual(archive.attachments.first { $0.kind == "EntitlementDiff" }?.bytes, try report.jsonData())
        XCTAssertTrue(try review.declarations(for:match).first { $0.category == .loadCommands }?.message.contains("Requested slice is missing") == true)
        XCTAssertThrowsError(try ComponentComparison.review(previous:a,current:b,architecture:.x86_64,entitlementResults:review.entitlementResults))
        let restored = try ComponentReviewArchive.decode(archive)
        guard case .compared(_,_,let reopened) = restored.entitlementResults[0] else { return XCTFail("Compared report") }
        XCTAssertEqual(reopened.changes.count,1)
    }
    func testArchiveReopensAndRejectsDanglingBindings() throws {
        let a = inventory(), b = inventory()
        let review = try ComponentComparison.review(previous:a,current:b,architecture:.arm64,entitlementResults:[])
        let bytes = try ComponentReviewArchive.encode(review)
        let archive = try InspectionArchive.decode(bytes)
        let restored = try ComponentReviewArchive.decode(archive)
        XCTAssertEqual(restored.previous.id, a.id)
        XCTAssertEqual(restored.matching.matches[0].id, review.matching.matches[0].id)
        let withoutInventory = InspectionArchive(attachments: archive.attachments.filter { $0.kind != ComponentInventoryDocumentCodec.kind })
        XCTAssertThrowsError(try withoutInventory.encode())
    }
}
