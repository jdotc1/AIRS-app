import XCTest
@testable import AIRSEntitlements

final class EntitlementReferenceCatalogTests: XCTestCase {
    func testInitialCatalogContainsExactlyThreeOfficialReferences() throws {
        for key in ["com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.network.server"] {
            let value = try XCTUnwrap(EntitlementReferenceCatalog.reference(forExactKey: key))
            XCTAssertEqual(value.key, key)
            XCTAssertEqual(value.sourceURL.host, "developer.apple.com")
            XCTAssertEqual(value.reviewedDate, "2026-10-20")
            XCTAssertTrue(value.scopeNote.contains("declaration"))
        }
    }
    func testUnknownEmptyAndByteDistinctKeysHaveNoInventedExplanation() {
        for key in ["", "unknown", "com.apple.security.network.client\u{301}", "com.apple.security.nétwork.client", "com.apple.security.ne\u{301}twork.client"] {
            XCTAssertNil(EntitlementReferenceCatalog.reference(forExactKey: key))
        }
    }
}
