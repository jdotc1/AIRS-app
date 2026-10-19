import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSApp

final class EntitlementLibraryTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-library-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func report() throws -> ComparisonReport {
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        return try ComparisonReport(previous: pair.previous, current: pair.current)
    }

    func testCompleteBytesSurviveNewStoreAndDeduplicate() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EntitlementReportLibrary(root: root)
        let report = try report(); let bytes = try report.jsonData()
        let id = try await store.keep(report)
        let duplicate = try await store.keep(report)
        XCTAssertEqual(id, duplicate)
        let reopened = try await EntitlementReportLibrary(root: root).load(id)
        XCTAssertEqual(reopened.data, bytes)
        XCTAssertTrue(reopened.report.previous.isSavedBaseline)
        XCTAssertTrue(reopened.report.current.isSavedBaseline)
        XCTAssertEqual(reopened.report.current.entitlements, report.current.entitlements)
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.summary?.architecture, "arm64")
    }

    func testCorruptRetainedCopyIsVisibleUnavailableAndDoesNotLoad() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = EntitlementReportLibrary(root: root)
        let id = try await store.keep(report())
        let url = root.appendingPathComponent("\(id.uuidString)/report.json")
        var data = try Data(contentsOf: url); data.append(32); try data.write(to: url)
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1); XCTAssertNotNil(entries[0].issue)
        do { _ = try await store.load(id); XCTFail("Corrupt copy opened") } catch {}
    }

    @MainActor
    func testKeepIgnoresBrowserFilterReviewCancelAndAdoptionPreserveAudit() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let library = EntitlementReportLibrary(root: root)
        let audit = AuditWorkspace()
        let auditStatus = audit.status
        let workspace = EntitlementsWorkspace(library: library)
        workspace.loadExample()
        let original = try XCTUnwrap(workspace.model.report)
        workspace.model.browser.query = "no matches"
        let revision = workspace.model.reportRevision
        await workspace.keepCurrentReport()?.value
        let id = try XCTUnwrap(workspace.libraryEntries.first?.id)
        let kept = try await library.load(id)
        XCTAssertEqual(kept.report.current.entitlements, original.current.entitlements)
        await workspace.openLibrary()?.value
        XCTAssertFalse(workspace.canFindEntitlement)
        await workspace.reviewRetainedReport(id)?.value
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertNotNil(workspace.savedReport)
        workspace.cancelReview()
        XCTAssertTrue(workspace.showingLibrary)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        await workspace.reviewRetainedReport(id)?.value
        workspace.openSavedComparison()
        XCTAssertFalse(workspace.showingLibrary)
        XCTAssertTrue(workspace.protectedInputs.contains(kept.reportURL))
        XCTAssertTrue(workspace.model.selectedSourceURLs.isEmpty)
        XCTAssertNotEqual(workspace.model.reportRevision, revision)
        XCTAssertNil(audit.report); XCTAssertEqual(audit.status, auditStatus)
    }

    @MainActor
    func testUnavailableEntryDoesNotReplaceComparisonAndRemovalKeepsSession() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root))
        workspace.loadExample()
        await workspace.keepCurrentReport()?.value
        let id = try XCTUnwrap(workspace.libraryEntries.first?.id)
        let revision = workspace.model.reportRevision
        let rawURL = root.appendingPathComponent("\(id.uuidString)/report.json")
        try FileManager.default.removeItem(at: rawURL)
        await workspace.reviewRetainedReport(id)?.value
        XCTAssertNotNil(workspace.errorMessage); XCTAssertNil(workspace.savedReport)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        workspace.errorMessage = nil
        await workspace.removeRetainedReport(id)?.value
        XCTAssertTrue(workspace.libraryEntries.isEmpty)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
    }

    @MainActor
    func testCancelledLibraryReadSuppressesLateStorageFailure() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: blocked))
        workspace.loadExample()
        let revision = workspace.model.reportRevision
        let review = try XCTUnwrap(workspace.reviewRetainedReport(UUID()))
        workspace.cancel()
        XCTAssertTrue(workspace.isWorking)
        await review.value
        XCTAssertNil(workspace.errorMessage); XCTAssertNil(workspace.savedReport)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        let refresh = try XCTUnwrap(workspace.openLibrary())
        workspace.cancel()
        await refresh.value
        XCTAssertNil(workspace.errorMessage)
        XCTAssertFalse(workspace.libraryLoaded)
        XCTAssertEqual(workspace.model.reportRevision, revision)
    }

    @MainActor
    func testCapacityFailureKeepsExistingReportAndFailedWriteSettlesQuit() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root, maximumEntries: 0))
        workspace.loadExample()
        let revision = workspace.model.reportRevision
        let task = try XCTUnwrap(workspace.keepCurrentReport())
        XCTAssertTrue(workspace.isWriting)
        XCTAssertNil(workspace.openLibrary())
        workspace.clear()
        XCTAssertEqual(workspace.model.reportRevision, revision)
        await task.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        let ready = await workspace.finishBeforeQuit()
        XCTAssertFalse(ready)
        XCTAssertFalse(workspace.isBusy)
    }
}
