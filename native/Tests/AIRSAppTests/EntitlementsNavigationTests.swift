import XCTest
import AIRSCore
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

final class EntitlementsNavigationTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor
    private func fixture() throws -> EntitlementsWorkspace {
        let workspace = EntitlementsWorkspace()
        let url = project.appendingPathComponent("fixtures/entitlements/navigation-report.json")
        workspace.reviewValidatedReport(try SavedReport.read(at: url), from: url)
        workspace.openSavedComparison()
        return workspace
    }

    @MainActor
    func testFindRevealsExactKeyAndPreservesCompleteSavedReport() throws {
        let workspace = try fixture()
        let bytes = try XCTUnwrap(workspace.model.report).jsonData()
        let revision = workspace.model.reportRevision
        let sources = workspace.protectedInputs
        workspace.model.browser.query = "099"
        workspace.model.browser.sortOrder = [BrowserSort(order: .reverse)]
        workspace.moveToChange(.next)
        let selection = workspace.model.browser.selection
        workspace.beginFindEntitlement()
        let session = try XCTUnwrap(workspace.entitlementFind)
        XCTAssertEqual(workspace.findEntitlement("é", revealHidden: false, sessionID: session.id), .hidden)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        XCTAssertEqual(workspace.model.browser.query, "099")
        XCTAssertEqual(workspace.findEntitlement("e\u{301}", revealHidden: false, sessionID: session.id), .missing)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        guard case .found(let id) = workspace.findEntitlement("é", revealHidden: true, sessionID: session.id) else {
            return XCTFail("Expected explicit reveal")
        }
        XCTAssertNil(workspace.entitlementFind)
        workspace.finishFindPresentation()
        XCTAssertEqual(workspace.findRevealID, id)
        XCTAssertEqual(workspace.model.browser.filter, .allKeys)
        XCTAssertEqual(workspace.model.browser.query, "")
        XCTAssertEqual(workspace.model.browser.sortOrder, [BrowserSort(order: .reverse)])
        let reveal = workspace.findRevealRevision
        workspace.beginFindEntitlement()
        let repeated = try XCTUnwrap(workspace.entitlementFind)
        XCTAssertEqual(workspace.findEntitlement("é", revealHidden: false, sessionID: repeated.id), .found(id))
        workspace.finishFindPresentation()
        XCTAssertNotEqual(workspace.findRevealRevision, reveal, "Repeated Find must reveal the same row again")
        XCTAssertEqual(try workspace.model.report?.jsonData(), bytes)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertEqual(workspace.protectedInputs, sources)
        XCTAssertTrue(workspace.model.current.snapshot?.isSavedBaseline == true)
    }

    @MainActor
    func testDismissedFindRevealsOnlyItsUnchangedSelectionAndReport() throws {
        for replaceReport in [false, true] {
            let workspace = try fixture()
            let initialReveal = workspace.findRevealRevision
            workspace.beginFindEntitlement()
            let session = try XCTUnwrap(workspace.entitlementFind)
            guard case .found = workspace.findEntitlement("é", revealHidden: true, sessionID: session.id) else {
                return XCTFail("Expected hidden-key adoption")
            }
            XCTAssertEqual(workspace.findRevealRevision, initialReveal, "Scroll must wait until the sheet dismisses")
            if replaceReport { workspace.swap() }
            else { workspace.model.browser.selection = nil }
            workspace.finishFindPresentation()
            XCTAssertEqual(workspace.findRevealRevision, initialReveal, "Never scroll a superseded result")
            workspace.finishFindPresentation()
            XCTAssertEqual(workspace.findRevealRevision, initialReveal)
        }
    }

    @MainActor
    func testFindSessionBlocksReplacementAndRejectsObsoleteCallbacks() throws {
        let workspace = try fixture()
        workspace.moveToChange(.next)
        let revision = workspace.model.reportRevision, selection = workspace.model.browser.selection
        workspace.beginFindEntitlement()
        let old = try XCTUnwrap(workspace.entitlementFind)
        XCTAssertTrue(workspace.isBusy)
        XCTAssertFalse(workspace.canMoveToChange(.next))
        workspace.moveToChange(.next)
        workspace.swap(); workspace.clear(); workspace.setArchitecture(.x86_64); workspace.loadExample()
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        workspace.cancelFindEntitlement(sessionID: old.id)
        workspace.beginFindEntitlement()
        let current = try XCTUnwrap(workspace.entitlementFind)
        workspace.cancelFindEntitlement(sessionID: old.id)
        XCTAssertEqual(workspace.entitlementFind?.id, current.id)
        XCTAssertEqual(workspace.findEntitlement("example.key.099", revealHidden: true, sessionID: old.id), .missing)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        workspace.model.swap() // Simulate replacement outside the normal guarded host actions.
        XCTAssertEqual(workspace.findEntitlement("example.key.099", revealHidden: true, sessionID: current.id), .missing)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        workspace.cancelFindEntitlement(sessionID: current.id)
        XCTAssertFalse(workspace.isBusy)
    }

    @MainActor
    func testChangeActionsUseVisibleOrderAndRevealWithoutMutatingReport() throws {
        let workspace = try fixture()
        let revision = workspace.model.reportRevision
        let bytes = try XCTUnwrap(workspace.model.report).jsonData()
        workspace.model.browser.filter = .allKeys
        workspace.moveToChange(.next)
        XCTAssertEqual(workspace.model.browser.selectedRow?.key, "example.key.000")
        XCTAssertFalse(workspace.canMoveToChange(.previous))
        let firstReveal = workspace.findRevealRevision
        workspace.moveToChange(.next)
        XCTAssertEqual(workspace.model.browser.selectedRow?.key, "example.key.099")
        XCTAssertEqual(workspace.findRevealID, workspace.model.browser.selection)
        XCTAssertNotEqual(workspace.findRevealRevision, firstReveal)
        XCTAssertEqual(workspace.model.browser.changePositionText, "Change 2 of 2 in this view")
        XCTAssertFalse(workspace.canMoveToChange(.next))
        let lastReveal = workspace.findRevealRevision
        workspace.moveToChange(.next)
        XCTAssertEqual(workspace.findRevealRevision, lastReveal, "Endpoint must not wrap")
        workspace.moveToChange(.previous)
        XCTAssertEqual(workspace.model.browser.selectedRow?.key, "example.key.000")
        workspace.model.browser.sortOrder = [BrowserSort(order: .reverse)]
        workspace.model.browser.selection = nil
        workspace.moveToChange(.next)
        XCTAssertEqual(workspace.model.browser.selectedRow?.key, "example.key.099")
        workspace.model.browser.query = "000"
        workspace.moveToChange(.previous)
        XCTAssertEqual(workspace.model.browser.selectedRow?.key, "example.key.000")
        XCTAssertFalse(workspace.canMoveToChange(.previous))
        XCTAssertFalse(workspace.canMoveToChange(.next))
        XCTAssertEqual(workspace.model.browser.query, "000")
        XCTAssertEqual(workspace.model.browser.filter, .allKeys)
        XCTAssertEqual(try workspace.model.report?.jsonData(), bytes)
        XCTAssertEqual(workspace.model.reportRevision, revision)
    }

    @MainActor
    func testFindOwnsSessionAgainstSharedOpenAndQuitResumesSafely() async throws {
        let workspace = try fixture(), audit = AuditWorkspace(), navigation = AIRSNavigation()
        let router = AIRSFileOpen(read: { _ in XCTFail("Must reject before reading"); throw CocoaError(.fileReadUnknown) }, hasModal: { false })
        workspace.beginFindEntitlement()
        let session = try XCTUnwrap(workspace.entitlementFind)
        XCTAssertNil(router.open([project.appendingPathComponent("examples/before.audit.json")], audit: audit,
                                 entitlements: workspace, navigation: navigation))
        let revision = workspace.model.reportRevision
        let ready = await workspace.finishBeforeQuit()
        XCTAssertTrue(ready)
        XCTAssertEqual(workspace.findEntitlement("example.key.099", revealHidden: true, sessionID: session.id), .missing)
        workspace.resumeAfterCancelledQuit()
        XCTAssertEqual(workspace.entitlementFind?.id, session.id)
        guard case .found = workspace.findEntitlement("example.key.099", revealHidden: false, sessionID: session.id) else {
            return XCTFail("Refused Quit must preserve the usable Find session")
        }
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertNil(audit.report)
    }

    @MainActor
    func testNavigationEligibilityPreservesAuditAndHonorsHostState() async throws {
        let audit = AuditWorkspace(), router = AIRSFileOpen(hasModal: { false }), navigation = AIRSNavigation()
        let workspace = try fixture()
        let data = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        audit.openValidatedReport(try AuditReport.decode(data), data: data,
                                  from: project.appendingPathComponent("examples/before.audit.json"))
        let auditRevision = audit.reportRevision
        XCTAssertFalse(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        navigation.showsEntitlements = true
        XCTAssertTrue(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        audit.showingError = true
        XCTAssertFalse(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        audit.showingError = false
        router.errorMessage = "Pending report error"
        XCTAssertFalse(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        router.errorMessage = nil
        await router.finishBeforeQuit()
        XCTAssertFalse(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        router.resumeAfterCancelledQuit()
        XCTAssertTrue(navigation.allowsEntitlementNavigation(audit: audit, fileOpen: router))
        workspace.moveToChange(.next)
        workspace.beginFindEntitlement()
        let session = try XCTUnwrap(workspace.entitlementFind)
        _ = workspace.findEntitlement("example.key.099", revealHidden: false, sessionID: session.id)
        XCTAssertEqual(audit.reportRevision, auditRevision)
        XCTAssertEqual(audit.report?.summary.functionCount, 3)
        workspace.errorMessage = "Pending entitlement error"
        XCTAssertFalse(workspace.canFindEntitlement)
        XCTAssertFalse(workspace.canMoveToChange(.previous))
        XCTAssertFalse(EntitlementsWorkspace().canFindEntitlement)
    }
}
