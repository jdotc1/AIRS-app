import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

@MainActor
private final class LibraryRecentsSpy: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
    func clearRecentDocuments() { recentDocumentURLs = [] }
}

final class ReportLibraryWorkspaceTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    @MainActor
    private func settle(_ workspace: AuditWorkspace) async throws {
        for _ in 0..<500 {
            if !workspace.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Library operation did not settle")
    }
    private func store() throws -> (URL, ReportLibrary) {
        let root = project.appendingPathComponent("build/report-library-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ReportLibrary(root: root))
    }

    @MainActor
    func testKeepReopenAndRecentRecordingWithoutPython() async throws {
        let (root, library) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let recents = LibraryRecentsSpy()
        let workspace = AuditWorkspace(library: library, recents: recents)
        let url = project.appendingPathComponent("examples/before.audit.json")
        workspace.showingLibrary = true
        workspace.importReport(url); try await settle(workspace)
        XCTAssertFalse(workspace.showingLibrary)
        XCTAssertEqual(recents.recentDocumentURLs, [url])
        workspace.keepCurrentReport(); try await settle(workspace)
        let id = try XCTUnwrap(workspace.libraryEntries.first?.id)
        let retained = try await library.load(id)
        XCTAssertEqual(retained.data, try Data(contentsOf: url))
        workspace.showingLibrary = true
        workspace.openRetainedReport(id); try await settle(workspace)
        XCTAssertFalse(workspace.showingLibrary)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, retained.report.image.sliceSHA256)
        XCTAssertEqual(recents.recentDocumentURLs.count, 1)
        workspace.importReport(root.appendingPathComponent("missing.json")); try await settle(workspace)
        XCTAssertTrue(workspace.showingError)
        XCTAssertEqual(recents.recentDocumentURLs.count, 1)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, retained.report.image.sliceSHA256)
        workspace.clearRecentReports()
        XCTAssertTrue(recents.recentDocumentURLs.isEmpty)
    }

    @MainActor
    func testMissingRetainedReportPreservesCurrentSelection() async throws {
        let (root, library) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AuditWorkspace(library: library, recents: LibraryRecentsSpy())
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let original = try XCTUnwrap(workspace.report)
        let selected = try XCTUnwrap(original.findings.first?.id)
        workspace.selection = .finding(selected)
        workspace.openRetainedReport(UUID()); try await settle(workspace)
        XCTAssertTrue(workspace.showingError)
        XCTAssertEqual(workspace.selectedFinding?.id, selected)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, original.image.sliceSHA256)
    }

    @MainActor
    func testRetainedBaselineUsesBeforeToCurrentDirection() async throws {
        let (root, library) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let baselineData = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        let id = try await library.keep(baselineData, provenance: LibraryProvenance(sourceLabel: "Before"))
        let workspace = AuditWorkspace(library: library, recents: LibraryRecentsSpy())
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let current = try XCTUnwrap(workspace.report)
        workspace.showingLibrary = true
        workspace.compareRetainedReport(id); try await settle(workspace)
        let comparison = try XCTUnwrap(workspace.comparisonDocument)
        XCTAssertFalse(workspace.showingLibrary)
        XCTAssertEqual(comparison.report.comparison.baselineImage.displayName, try AuditReport.decode(baselineData).image.displayName)
        XCTAssertEqual(comparison.report.comparison.currentImage.displayName, current.image.displayName)
        XCTAssertEqual(comparison.report.summary.changedCount, 2)
        XCTAssertEqual(comparison.report.summary.unchangedCount, 1)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, current.image.sliceSHA256)
    }

    @MainActor
    func testQuitSettlesOwnedLibraryWrite() async throws {
        let (root, library) = try store(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = AuditWorkspace(library: library, recents: LibraryRecentsSpy())
        workspace.importReport(project.appendingPathComponent("examples/before.audit.json")); try await settle(workspace)
        workspace.keepCurrentReport()
        XCTAssertTrue(workspace.isBusy)
        XCTAssertFalse(workspace.canCancel)
        let canQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(canQuit)
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
    }
}
