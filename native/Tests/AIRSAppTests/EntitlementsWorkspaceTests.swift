import AppKit
import XCTest
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

private actor EntitlementGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            waiting?.resume(); waiting = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func finish(_ result: Result<Value, Error>) { continuation?.resume(with: result); continuation = nil }
}

private struct HeldEntitlementReader: SnapshotReading {
    let gate: EntitlementGate<EntitlementSnapshot>
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot { try await gate.wait() }
}

final class EntitlementsWorkspaceTests: XCTestCase {
    private func saved() throws -> SavedReport {
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        return try SavedReport.parse(EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current).jsonData())
    }

    @MainActor
    func testCancelImportPreservesExistingComparison() async throws {
        let gate = EntitlementGate<SavedReport>()
        let workspace = EntitlementsWorkspace(readReport: { _ in try await gate.wait() })
        workspace.loadExample()
        let revision = workspace.model.reportRevision
        let task = try XCTUnwrap(workspace.openSavedReport(URL(fileURLWithPath: "/unused.json")))
        await gate.started()
        workspace.cancel()
        XCTAssertTrue(workspace.isWorking, "Cancellation retains ownership until the read settles")
        await gate.finish(.success(try saved()))
        await task.value
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertNotNil(workspace.model.report)
        XCTAssertNil(workspace.savedReport)
        XCTAssertFalse(workspace.isWorking)
    }
    @MainActor
    func testRejectedHostQuitPreservesIdleEntitlementSession() async throws {
        let workspace = EntitlementsWorkspace()
        workspace.loadExample()
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        let revision = workspace.model.reportRevision
        let selection = workspace.model.browser.selection
        let ready = await workspace.finishBeforeQuit()
        XCTAssertTrue(ready)
        workspace.resumeAfterCancelledQuit()
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertEqual(workspace.model.browser.selection, selection)
        XCTAssertNotNil(workspace.model.report)
        XCTAssertFalse(workspace.isBusy)
    }

    @MainActor
    func testAuditCommandRevealsAuditWorkspaceBeforeApplyingAction() {
        let navigation = AIRSNavigation()
        navigation.showsEntitlements = true
        var actionCalled = false
        navigation.performAudit {
            actionCalled = true
            XCTAssertFalse(navigation.showsEntitlements)
        }
        XCTAssertTrue(actionCalled)
        XCTAssertFalse(navigation.showsEntitlements)
    }

    @MainActor
    func testCancelledNativeReadCannotPublishAndRetainsSettlement() async throws {
        let gate = EntitlementGate<EntitlementSnapshot>()
        let workspace = EntitlementsWorkspace(reader: HeldEntitlementReader(gate: gate))
        let task = try XCTUnwrap(workspace.inspect(URL(fileURLWithPath: "/Late.app"), side: .previous))
        await gate.started()
        workspace.cancel()
        XCTAssertTrue(workspace.isWorking)
        XCTAssertNil(workspace.inspect(URL(fileURLWithPath: "/Other.app"), side: .current))
        await gate.finish(.success(ExampleSnapshots.pair(architecture: .arm64).previous))
        await task.value
        XCTAssertTrue(workspace.model.previous.isEmpty)
        XCTAssertNil(workspace.model.report)
        XCTAssertTrue(workspace.model.selectedSourceURLs.isEmpty)
        XCTAssertFalse(workspace.isWorking)
        workspace.setArchitecture(.x86_64)
        XCTAssertEqual(workspace.model.architecture, .x86_64)
    }

    @MainActor
    func testSavedReviewAdoptionAndExplicitArchitectureInvalidation() async throws {
        let value = try saved()
        let workspace = EntitlementsWorkspace(readReport: { _ in value })
        workspace.loadExample()
        let original = workspace.model.reportRevision
        let url = URL(fileURLWithPath: "/Saved-entitlements.json")
        await workspace.openSavedReport(url)?.value
        XCTAssertEqual(workspace.model.reportRevision, original, "Reading only stages review")
        XCTAssertTrue(workspace.isBusy)
        workspace.openSavedComparison()
        XCTAssertNotEqual(workspace.model.reportRevision, original)
        XCTAssertTrue(try XCTUnwrap(workspace.model.previous.snapshot).isSavedBaseline)
        XCTAssertTrue(try XCTUnwrap(workspace.model.current.snapshot).isSavedBaseline)
        XCTAssertTrue(workspace.model.selectedSourceURLs.isEmpty)
        XCTAssertFalse(workspace.model.canReload(.previous))
        XCTAssertEqual(workspace.protectedInputs, [url])
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        workspace.setArchitecture(.x86_64)
        XCTAssertNil(workspace.model.report)
        XCTAssertNil(workspace.model.browser.selectedRow)
        XCTAssertTrue(workspace.protectedInputs.isEmpty)
    }

    @MainActor
    func testImportRejectsAuditFormatAndStaleReview() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("audit.json")
        try Data(#"{"schema_version":1,"report_kind":"airs.audit"}"#.utf8).write(to: file)
        let workspace = EntitlementsWorkspace()
        workspace.loadExample()
        let original = workspace.model.reportRevision
        await workspace.openSavedReport(file)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertNil(workspace.savedReport)
        XCTAssertEqual(workspace.model.reportRevision, original)
        let gate = EntitlementGate<SavedReport>()
        let pending = EntitlementsWorkspace(readReport: { _ in try await gate.wait() })
        let task = try XCTUnwrap(pending.openSavedReport(file))
        await gate.started()
        pending.model.setArchitecture(.x86_64)
        await gate.finish(.success(try saved()))
        await task.value
        XCTAssertNil(pending.savedReport, "Revision guard rejects a stale review")
        XCTAssertEqual(pending.model.architecture, .x86_64)
    }

    @MainActor
    func testCompleteExportProtectsSourceAndIgnoresFilter() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let sourceBytes = try EntitlementDiffCore.ComparisonReport(previous: saved().previous, current: saved().current).jsonData()
        try sourceBytes.write(to: source)
        let workspace = EntitlementsWorkspace()
        await workspace.openSavedReport(source)?.value
        workspace.openSavedComparison()
        workspace.model.browser.query = "no-such-key"
        XCTAssertTrue(workspace.model.browser.visibleRows.isEmpty)
        let destination = directory.appendingPathComponent("complete.json")
        await workspace.export(to: destination)?.value
        let reopened = try SavedReport.read(at: destination)
        XCTAssertEqual(reopened.previous.entitlements, workspace.model.previous.snapshot?.entitlements)
        XCTAssertEqual(reopened.current.entitlements, workspace.model.current.snapshot?.entitlements)
        await workspace.export(to: source)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        let input = directory.appendingPathComponent("Input.app")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        do {
            try await EntitlementsWorkspace.writeSaved(try XCTUnwrap(workspace.model.report), input.appendingPathComponent("bad.json"), [input])
            XCTFail("Must reject writes inside a selected app")
        } catch ReportDestinationError.insideInputBundle { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.appendingPathComponent("bad.json").path))
    }

    @MainActor
    func testCopyRejectsChangedSelection() async throws {
        let workspace = EntitlementsWorkspace()
        workspace.loadExample()
        workspace.model.browser.selection = workspace.model.browser.visibleRows.first?.id
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("keep", forType: .string)
        let task = try XCTUnwrap(workspace.copySelected(to: clipboard))
        workspace.model.browser.selection = nil
        await task.value
        XCTAssertEqual(clipboard.string(forType: .string), "keep")
        XCTAssertTrue(workspace.status.contains("nothing copied"))
    }

    @MainActor
    func testQuitWaitsForWriteFailureAndAllowsRecovery() async throws {
        let gate = EntitlementGate<Void>()
        let workspace = EntitlementsWorkspace(writeReport: { _, _, _ in try await gate.wait() })
        workspace.loadExample()
        let task = try XCTUnwrap(workspace.export(to: URL(fileURLWithPath: "/unused.json")))
        await gate.started()
        XCTAssertFalse(workspace.canCancel)
        let quit = Task { await workspace.finishBeforeQuit() }
        await Task.yield()
        XCTAssertTrue(workspace.isWorking)
        await gate.finish(.failure(CocoaError(.fileWriteNoPermission)))
        await task.value
        let shouldQuit = await quit.value
        XCTAssertFalse(shouldQuit)
        XCTAssertFalse(workspace.isBusy)
        XCTAssertNotNil(workspace.model.report)
        XCTAssertNotNil(workspace.errorMessage)
    }

    @MainActor
    func testExportFailureVetoIsConsumedAfterCancelledQuit() async throws {
        let workspace = EntitlementsWorkspace(writeReport: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })
        workspace.loadExample()
        await workspace.export(to: URL(fileURLWithPath: "/unused.json"))?.value
        let first = await workspace.finishBeforeQuit()
        XCTAssertFalse(first)
        workspace.resumeAfterCancelledQuit()
        let second = await workspace.finishBeforeQuit()
        XCTAssertTrue(second, "An acknowledged settled failure must not permanently veto audit quit")
    }

    private func testDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlements-integration-evidence/tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
