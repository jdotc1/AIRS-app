import AppKit
import XCTest
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

final class EntitlementsInspectorTests: XCTestCase {
    @MainActor
    func testRetainedInspectorActionRejectsSameKeyNewReport() throws {
        let workspace = EntitlementsWorkspace()
        workspace.loadExample()
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        let change = try XCTUnwrap(workspace.model.browser.selectedRow)
        let row = try XCTUnwrap(InspectorBranchNavigator(previous: change.previous, current: change.current).rows.first(where: { $0.hasLeafValue }))
        let oldView = EntitlementsBrowser(workspace: workspace).detailView
        workspace.swap()
        oldView.inspect(change, row)
        XCTAssertNil(workspace.focusedValue, "An old view must not borrow a replacement report's revision")
    }

    @MainActor
    private func fixture() throws -> (EntitlementsWorkspace, EntitlementChange) {
        func snapshot(_ name: String, _ values: [String: EntitlementValue]) -> EntitlementSnapshot {
            .init(sourceName: name, signingIdentifier: "test.inspector", architecture: .arm64,
                  origin: .syntheticExample, entitlements: .init(["fixture": .dictionary(.init(values))]))
        }
        let old = snapshot("Previous.app", ["text": .string("aé-tail"), "bytes": .data(Data([0, 0xab, 0xcd, 9]))])
        let new = snapshot("Current.app", ["text": .string("bé-tail"), "bytes": .data(Data([1, 0xab, 0xcd, 8]))])
        let saved = try SavedReport.parse(EntitlementDiffCore.ComparisonReport(previous: old, current: new).jsonData())
        let workspace = EntitlementsWorkspace()
        workspace.model.openSavedComparison(saved)
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        return (workspace, try XCTUnwrap(workspace.model.browser.selectedRow))
    }

    @MainActor
    func testTreeTextFocusCopyAndStaleRevision() async throws {
        let (workspace, change) = try fixture()
        let session = TreeTextSearchSession(change: change, revision: workspace.model.reportRevision)
        session.setQuery(.init(value: "é"))
        await session.search()?.value
        let hit = try XCTUnwrap(session.cursor?.hits.first)
        session.selectHit(hit.id)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        workspace.copyTreeResultDetails(session, to: clipboard)
        XCTAssertTrue(try XCTUnwrap(clipboard.string(forType: .string)).contains("C3 A9"))
        workspace.openTreeHit(session, hit: hit)
        XCTAssertEqual(workspace.focusedValue?.initialScalar, 2)
        XCTAssertEqual(workspace.focusedValue?.initialMatchRange, 1..<3)
        XCTAssertEqual(workspace.focusedValue?.initialSide, .previous)
        let revision = workspace.model.reportRevision
        workspace.swap(); workspace.clear(); workspace.setArchitecture(.x86_64)
        XCTAssertEqual(workspace.model.reportRevision, revision, "Focused sheet owns the session")
        workspace.focusedValue = nil
        workspace.swap()
        clipboard.setString("keep", forType: .string)
        workspace.copyTreeResultDetails(session, to: clipboard)
        workspace.openTreeHit(session, hit: hit)
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
        XCTAssertNil(workspace.focusedValue)
    }

    @MainActor
    func testTreeHexFocusAndSelectionGuard() async throws {
        let (workspace, change) = try fixture()
        let session = TreeHexSearchSession(change: change, revision: workspace.model.reportRevision)
        session.setScope(.current)
        session.setQuery(.init(value: "AB CD"))
        await session.search()?.value
        let hit = try XCTUnwrap(session.cursor?.hits.first)
        session.selectHit(hit.id)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        workspace.copyTreeHexResultDetails(session, to: clipboard)
        XCTAssertTrue(try XCTUnwrap(clipboard.string(forType: .string)).contains("AB CD"))
        workspace.openTreeHexHit(session, hit: hit)
        XCTAssertEqual(workspace.focusedValue?.initialByte, 2)
        XCTAssertEqual(workspace.focusedValue?.initialSide, .current)
        XCTAssertNil(workspace.focusedValue?.previous)
        XCTAssertEqual(workspace.focusedValue?.current, .data(Data([1, 0xab, 0xcd, 8])))
        workspace.focusedValue = nil
        workspace.model.browser.selection = nil
        clipboard.setString("keep", forType: .string)
        workspace.copyTreeHexResultDetails(session, to: clipboard)
        workspace.openTreeHexHit(session, hit: hit)
        XCTAssertNil(workspace.focusedValue)
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
    }

    @MainActor
    func testFocusedLeafCopyIsCompleteAndRejectsReplacement() async throws {
        let (workspace, change) = try fixture()
        let row = try XCTUnwrap(InspectorBranchNavigator(previous: change.previous, current: change.current).rows.first(where: { $0.hasLeafValue }))
        workspace.inspectValue(change, row: row, comparisonRevision: workspace.model.reportRevision)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        await workspace.copyLeaf(.current, to: clipboard)?.value
        let expected = try XCTUnwrap(InspectorLeaf(row.current)).jsonData()
        XCTAssertEqual(clipboard.data(forType: .string), expected)
        clipboard.setString("keep", forType: .string)
        let pending = try XCTUnwrap(workspace.copyLeaf(.current, to: clipboard))
        XCTAssertTrue(workspace.requiresQuitSettlement)
        workspace.focusedValue = nil
        await pending.value
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
        XCTAssertFalse(workspace.isWorking)
    }

    @MainActor
    func testBranchCopyCompleteAndRejectsChangedSelection() async throws {
        let workspace = EntitlementsWorkspace()
        workspace.loadExample()
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        let change = try XCTUnwrap(workspace.model.browser.selectedRow)
        let root = InspectorBranchNavigator(previous: change.previous, current: change.current).root
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        await workspace.copyBranch(.current, row: root, entitlementID: change.id,
                                   comparisonRevision: workspace.model.reportRevision, to: clipboard)?.value
        XCTAssertEqual(clipboard.data(forType: .string), try XCTUnwrap(BranchJSONValue(root.current)).jsonData())
        clipboard.setString("keep", forType: .string)
        let pending = try XCTUnwrap(workspace.copyBranch(.current, row: root, entitlementID: change.id,
                                   comparisonRevision: workspace.model.reportRevision, to: clipboard))
        workspace.model.browser.selection = nil
        await pending.value
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
    }

    @MainActor
    func testQuitCancelsPendingLeafCopyWithoutLosingComparison() async throws {
        let (workspace, change) = try fixture()
        let row = try XCTUnwrap(InspectorBranchNavigator(previous: change.previous, current: change.current).rows.first(where: { $0.hasLeafValue }))
        workspace.inspectValue(change, row: row, comparisonRevision: workspace.model.reportRevision)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("keep", forType: .string)
        let pending = try XCTUnwrap(workspace.copyLeaf(.current, to: clipboard))
        let ready = await workspace.finishBeforeQuit()
        await pending.value
        XCTAssertTrue(ready)
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
        XCTAssertNotNil(workspace.model.report)
        workspace.resumeAfterCancelledQuit()
        XCTAssertNotNil(workspace.focusedValue)
    }
}
