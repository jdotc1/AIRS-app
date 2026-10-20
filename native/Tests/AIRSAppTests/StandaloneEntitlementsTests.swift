import Foundation
import XCTest
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

private struct StandaloneFixtureReader: SnapshotReading {
    let snapshot: EntitlementSnapshot
    var failingName: String? = nil

    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        if url.lastPathComponent == failingName { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
}

final class StandaloneEntitlementsTests: XCTestCase {
    private func snapshot(_ entries: [EntitlementEntry] = [
        .init(key: "example.boolean", value: .boolean(true)),
        .init(key: "example.string", value: .string("captured value"))
    ], presence: EntitlementPresence = .dictionaryPresent) throws -> EntitlementSnapshot {
        .init(sourceName: "One.app", signingIdentifier: "example.one",
              architecture: .arm64, presence: presence,
              entitlements: try EntitlementDictionary(entries: entries))
    }

    @MainActor
    func testOnePreviousSnapshotIsInspectableWithoutCreatingAComparison() throws {
        let workspace = EntitlementsWorkspace()
        workspace.model.useSavedBaseline(try snapshot())
        let input = try XCTUnwrap(workspace.standaloneInspection)
        XCTAssertEqual(input.side, .previous)
        XCTAssertTrue(input.snapshot.isSavedBaseline)
        XCTAssertEqual(input.entries.count, 2)
        XCTAssertTrue(workspace.model.current.isEmpty)
        XCTAssertNil(workspace.model.report)
        XCTAssertTrue(workspace.model.rows.isEmpty, "Standalone browsing must not invent added/removed changes")
    }

    @MainActor
    func testOneCurrentInputKeepsItsActualSide() async throws {
        let workspace = EntitlementsWorkspace(reader: StandaloneFixtureReader(snapshot: try snapshot()))
        await workspace.inspect(URL(fileURLWithPath: "/fixtures/One.app"), side: .current)?.value
        let input = try XCTUnwrap(workspace.standaloneInspection)
        XCTAssertEqual(input.side, .current)
        XCTAssertFalse(input.snapshot.isSavedBaseline)
        XCTAssertTrue(workspace.model.previous.isEmpty)
        XCTAssertNil(workspace.model.report)
        XCTAssertEqual(input.snapshot.sourceName, "One.app")
    }

    @MainActor
    func testEmptyWorkspaceAndTwoReadySnapshotsDoNotUseStandaloneMode() {
        let workspace = EntitlementsWorkspace()
        XCTAssertNil(workspace.standaloneInspection)
        workspace.loadExample()
        XCTAssertNotNil(workspace.model.report)
        XCTAssertNil(workspace.standaloneInspection)
    }

    @MainActor
    func testFailedInputNeverBecomesTheStandaloneSource() async throws {
        let workspace = EntitlementsWorkspace(
            reader: StandaloneFixtureReader(snapshot: try snapshot(), failingName: "Broken.app"))
        await workspace.inspect(URL(fileURLWithPath: "/fixtures/Broken.app"), side: .current)?.value
        XCTAssertNil(workspace.standaloneInspection, "Failure is not an empty successful snapshot")
        workspace.model.useSavedBaseline(try snapshot())
        await workspace.inspect(URL(fileURLWithPath: "/fixtures/Broken.app"), side: .current)?.value
        let input = try XCTUnwrap(workspace.standaloneInspection)
        XCTAssertEqual(input.side, .previous)
        XCTAssertNotNil(workspace.model.current.errorMessage)
        XCTAssertNil(workspace.model.report)
    }

    func testAbsentAndPresentEmptySnapshotsRemainDistinct() throws {
        let absent = StandaloneEntitlementInspection(side: .current,
            snapshot: try snapshot([], presence: .notPresent), revision: UUID())
        let empty = StandaloneEntitlementInspection(side: .current,
            snapshot: try snapshot([]), revision: UUID())
        XCTAssertTrue(absent.entries.isEmpty)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(absent.snapshot.presence, .notPresent)
        XCTAssertEqual(empty.snapshot.presence, .dictionaryPresent)
        XCTAssertNotEqual(absent.emptyMessage, empty.emptyMessage)
    }

    func testByteDistinctKeysKeepSeparateIdentitiesAndValues() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let input = StandaloneEntitlementInspection(side: .previous,
            snapshot: try snapshot([
                .init(key: composed, value: .integer(11)),
                .init(key: decomposed, value: .integer(22))
            ]), revision: UUID())
        XCTAssertEqual(Set(input.entries.map(\.id)).count, 2)
        let first = try XCTUnwrap(input.entry(forExactKey: composed))
        let second = try XCTUnwrap(input.entry(forExactKey: decomposed))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.value, .integer(11))
        XCTAssertEqual(second.value, .integer(22))
    }

    func testFilteringCannotDisplayAHiddenSelectionAndNewRevisionResetsNavigationIdentity() throws {
        let old = StandaloneEntitlementInspection(side: .current, snapshot: try snapshot(), revision: UUID())
        var browser = StandaloneEntitlementBrowser(input: old)
        let selected = try XCTUnwrap(old.entry(forExactKey: "example.string"))
        browser.selection = selected.id
        browser.query = "boolean"
        XCTAssertNil(browser.selectedEntry, "The detail must not show a key excluded by the filter")
        browser.query = ""
        browser.selection = selected.id

        let new = StandaloneEntitlementInspection(side: .current, snapshot: try snapshot([
            .init(key: "example.boolean", value: .boolean(false)),
            .init(key: "example.string", value: .string("replacement"))
        ]), revision: UUID())
        browser.replaceInput(new)
        XCTAssertEqual(browser.input.revision, new.revision)
        XCTAssertNotEqual(browser.input.revision, old.revision)
        XCTAssertEqual(browser.query, "")
        XCTAssertNotEqual(browser.selection, selected.id)
        XCTAssertEqual(old.entry(forExactKey: "example.string")?.value, .string("captured value"),
                       "Old captured input stays immutable; the live browser adopts a new revision")
        XCTAssertEqual(browser.input.entry(forExactKey: "example.string")?.value, .string("replacement"))
    }

    func testStandaloneBranchesReusePagedTraversalForTheSelectedSideOnly() throws {
        let values = (0..<73).map { EntitlementValue.integer(Int64($0)) }
        let value = EntitlementValue.dictionary(try EntitlementDictionary(entries: [
            .init(key: "array", value: .array(values)),
            .init(key: "e\u{0301}", value: .string("decomposed")),
            .init(key: "\u{00E9}", value: .string("composed"))
        ]))
        for side in ComparisonSide.allCases {
            var navigator = StandaloneValueNavigator(value: value, side: side)
            XCTAssertEqual(navigator.root.value, value)
            XCTAssertTrue(navigator.findExactChild("\u{00E9}"))
            XCTAssertEqual(navigator.exactChild?.value, .string("composed"))
            XCTAssertTrue(navigator.findExactChild("e\u{0301}"))
            XCTAssertEqual(navigator.exactChild?.value, .string("decomposed"))
            let array = try XCTUnwrap(navigator.rows.first { $0.label == "\"array\"" })
            XCTAssertTrue(navigator.enter(array.id))
            XCTAssertFalse(navigator.enter(array.id), "A parent-frame action must not resolve in the child frame")
            XCTAssertEqual(navigator.rows.count, 50)
            XCTAssertEqual(navigator.rows.first?.value, .integer(0))
            navigator.nextPage()
            XCTAssertEqual(navigator.rows.count, 23)
            XCTAssertEqual(navigator.rows.first?.value, .integer(50))
            XCTAssertFalse(navigator.hasNext)
            navigator.back()
            XCTAssertEqual(navigator.root.value, value)
        }
    }
}
