import XCTest
@testable import AIRSApp

final class AppIntakeTests: XCTestCase {
    func testOneAppStagesTaskChoiceAndPairPreservesReceivedOrder() throws {
        let a = URL(fileURLWithPath: "/Z-new.app"), b = URL(fileURLWithPath: "/A-old.app")
        guard case .chooseTask(let url) = try AppIntake.stage([a]) else { return XCTFail("Choice required") }
        XCTAssertEqual(url, a)
        guard case .compare(let previous, let current) = try AppIntake.stage([a,b]) else { return XCTFail("Pair required") }
        XCTAssertEqual(previous, a); XCTAssertEqual(current, b)
    }
    func testUnsupportedIntakeIsRejected() {
        let app = URL(fileURLWithPath: "/A.app")
        for urls in [[], [app,app,app], [URL(string: "https://example.com/A.app")!],
                     [app,URL(fileURLWithPath: "/report.json")], [URL(fileURLWithPath: "/unknown.airsinspect")]] {
            XCTAssertThrowsError(try AppIntake.stage(urls))
        }
    }
}

extension AppIntakeTests {
    @MainActor
    func testStagingCancelAndStaleConfirmationPreserveSessions() throws {
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        entitlements.loadExample()
        let original = entitlements.model.reportRevision
        let router = AIRSFileOpen(hasModal: { false })
        let urls = [URL(fileURLWithPath: "/Z.app"), URL(fileURLWithPath: "/A.app")]
        router.open(urls, audit: audit, entitlements: entitlements, navigation: navigation)
        XCTAssertNotNil(router.intakeReview)
        XCTAssertEqual(entitlements.model.reportRevision, original)
        router.swapIntake()
        guard case .compare(let previous, let current) = try XCTUnwrap(router.intakeReview).request else { return XCTFail("Pair") }
        XCTAssertEqual(previous, urls[1]); XCTAssertEqual(current, urls[0])
        router.intakeReview = nil
        XCTAssertEqual(entitlements.model.reportRevision, original)
        router.open(urls, audit: audit, entitlements: entitlements, navigation: navigation)
        entitlements.model.clear()
        let replaced = entitlements.model.reportRevision
        router.confirmIntake(audit: audit, entitlements: entitlements, navigation: navigation)
        XCTAssertNil(router.intakeReview)
        XCTAssertEqual(entitlements.model.reportRevision, replaced)
        XCTAssertTrue(entitlements.model.selectedSourceURLs.isEmpty)
    }
}
