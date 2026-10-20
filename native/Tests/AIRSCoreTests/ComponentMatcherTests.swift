import XCTest
@testable import AIRSCore
final class ComponentMatcherTests: XCTestCase {
    func inventory(_ rows: [ComponentRecord], completion: InventoryCompletion = .completeWithinScope,
                   locations: [String] = ["Contents/Helpers"], exclusions: [String] = []) -> ComponentInventory {
        .init(scope: .init(searchedLocations: locations, completion: completion, exclusions: exclusions, issues: []), components: rows)
    }
    func row(_ path: String, identifier: String? = nil) -> ComponentRecord {
        .init(relativePath: "Contents/Helpers/" + path, kind: "helper", declaredBundleID: identifier, architectures: ["arm64"])
    }
    func testExactPathMatchPreservesIdentifierChange() throws {
        let old = row("same", identifier: "old"), new = row("same", identifier: "new")
        let a = inventory([old]), b = inventory([new])
        let result = try ComponentMatcher.match(previous: a, current: b)
        XCTAssertEqual(result.matches.first?.relation, .sameLocation)
        XCTAssertEqual(result.matches.first?.previousID, old.id)
        XCTAssertTrue(result.matches[0].reasons.contains { $0.contains("identifier") })
        XCTAssertEqual(try ComponentMatcher.match(previous: a, current: b).matches[0].id, result.matches[0].id)
    }
    func testDuplicateIdentifiersRemainAmbiguous() throws {
        let result = try ComponentMatcher.match(previous: inventory([row("a", identifier: "duplicate"), row("b", identifier: "duplicate")]), current: inventory([row("c", identifier: "duplicate")]))
        XCTAssertTrue(result.matches.allSatisfy { $0.relation == .ambiguous })
    }
    func testUniqueIdentifierMoveIsCandidateOnly() throws {
        let result = try ComponentMatcher.match(previous: inventory([row("before", identifier: "same")]), current: inventory([row("after", identifier: "same")]))
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].relation, .uniqueIdentifierCandidate)
    }
    func testUTF8DistinctPathsDoNotMerge() throws {
        let result = try ComponentMatcher.match(previous: inventory([row("é")]), current: inventory([row("e\u{301}")]))
        XCTAssertEqual(Set(result.matches.map(\.relation)), [.addedWithinScope, .removedWithinScope])
    }
    func testPartialTraversalCannotProveRemoval() throws {
        let old = inventory([row("removed")])
        for other in [inventory([], completion: .partial), inventory([], locations: ["Contents/Frameworks"]), inventory([], exclusions: ["unreadable path"])] {
            let result = try ComponentMatcher.match(previous: old, current: other)
            XCTAssertEqual(result.matches[0].relation, .unobservedInOtherScope)
        }
    }
}
