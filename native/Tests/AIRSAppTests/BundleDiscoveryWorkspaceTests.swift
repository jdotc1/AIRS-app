import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

@MainActor private final class DiscoveryRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) {}
    func clearRecentDocuments() {}
}
private actor DiscoveryWorkspaceCalls {
    var paths: [URL] = []
    func add(_ path: URL) { paths.append(path) }
    func values() -> [URL] { paths }
}
final class BundleDiscoveryWorkspaceTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    @MainActor private func settle(_ workspace: AuditWorkspace) async throws {
        for _ in 0..<500 { if !workspace.isBusy { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Discovery operation did not settle")
    }
    private func fixture() throws -> (URL, URL, Data) {
        let root = project.appendingPathComponent("build/bundle-discovery-evidence/workspace-tests/\(UUID())"), app = root.appendingPathComponent("Owned.app")
        for folder in ["Contents/MacOS", "Contents/Frameworks", "Contents/Helpers"] { try FileManager.default.createDirectory(at: app.appendingPathComponent(folder), withIntermediateDirectories: true) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Main"], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let image = try Data(contentsOf: project.appendingPathComponent("fixtures/generated/before.macho"))
        for file in ["Contents/MacOS/Main", "Contents/Frameworks/failure", "Contents/Helpers/success"] { try image.write(to: app.appendingPathComponent(file)) }
        return (root, app, try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json")))
    }
    @MainActor
    func testDiscoveryRequiresSelectionAndBatchKeepsAllOutcomesAndProvenance() async throws {
        let (root, app, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library")), calls = DiscoveryWorkspaceCalls()
        let workspace = AuditWorkspace(library: library, recents: DiscoveryRecents(), batchAudit: { input in
            await calls.add(input); if input.lastPathComponent == "failure" { throw CocoaError(.fileReadUnknown) }; return raw
        }, batchHistory: history)
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let identity = workspace.report?.image.sliceSHA256
        workspace.discoverBundle(app); try await settle(workspace)
        let inventory = try XCTUnwrap(workspace.bundleDiscovery)
        XCTAssertEqual(inventory.entries.filter(\.selectable).count, 3); let before = await calls.values(); XCTAssertTrue(before.isEmpty)
        workspace.analyzeDiscoveredImages([]); XCTAssertNil(workspace.batchSnapshot); XCTAssertNotNil(workspace.bundleDiscovery)
        workspace.showingError = false
        workspace.analyzeDiscoveredImages(Set(inventory.entries.filter(\.selectable).map(\.id))); try await settle(workspace)
        let batch = try XCTUnwrap(workspace.batchSnapshot)
        XCTAssertEqual(batch.items.map(\.status), [.completed, .failed, .completed]); XCTAssertNil(workspace.bundleDiscovery)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, identity)
        let saved = try await history.load(batch.id)
        XCTAssertTrue(saved.items.allSatisfy { $0.bundleImage?.bundle == app && $0.bundleImage?.inventoryID == inventory.id })
        let retained = try await library.load(XCTUnwrap(saved.items[0].retainedReportID))
        XCTAssertEqual(retained.data, raw); XCTAssertEqual(retained.provenance.bundleImage, batch.items[0].bundleImage)
        workspace.openBatchReport(batch.items[0]); try await settle(workspace)
        XCTAssertThrowsError(try workspace.validateExportDestination(app.appendingPathComponent("Contents/Resources/export.json"), protectedInputs: []))
        workspace.keepCurrentReport(); try await settle(workspace)
        let count = try await library.entries().count; XCTAssertEqual(count, 2, "Keep must not strip bundle context into a new receipt")
    }
    @MainActor
    func testChangedSelectedCandidateFailsButNextSelectionRemainsUsableAndRetryKeepsProvenance() async throws {
        let (root, app, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library"), history = BatchHistory(root: root.appendingPathComponent("history"))
        try Data().write(to: libraryURL)
        let calls = DiscoveryWorkspaceCalls(), workspace = AuditWorkspace(library: ReportLibrary(root: libraryURL), recents: DiscoveryRecents(), batchAudit: { input in await calls.add(input); return raw }, batchHistory: history)
        workspace.discoverBundle(app); try await settle(workspace)
        let inventory = try XCTUnwrap(workspace.bundleDiscovery), rows = inventory.entries.filter(\.selectable)
        let main = try XCTUnwrap(rows.first { $0.relativePath.hasSuffix("Main") }), helper = try XCTUnwrap(rows.first { $0.relativePath.hasSuffix("success") })
        try Data("Changed after review".utf8).write(to: app.appendingPathComponent(main.relativePath))
        workspace.analyzeDiscoveredImages([main.id, helper.id]); try await settle(workspace)
        let batch = try XCTUnwrap(workspace.batchSnapshot)
        XCTAssertEqual(batch.items.map(\.status), [.failed, .completed]); XCTAssertTrue(workspace.hasUnretainedBatchReports)
        let audited = await calls.values(); XCTAssertEqual(audited, [app.appendingPathComponent(helper.relativePath)])
        try FileManager.default.removeItem(at: libraryURL)
        workspace.retryBatchRetention(batch.items[1]); try await settle(workspace)
        let retainedID = try XCTUnwrap(workspace.batchSnapshot?.items[1].retainedReportID)
        let retained = try await ReportLibrary(root: libraryURL).load(retainedID)
        XCTAssertEqual(retained.provenance.bundleImage?.relativePath, helper.relativePath); XCTAssertEqual(retained.data, raw)
    }
    @MainActor
    func testInvalidBundleLeavesCurrentReportAndComparisonExportCarriesBundle() async throws {
        let (root, app, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library"))
        let workspace = AuditWorkspace(library: library, recents: DiscoveryRecents(), batchAudit: { _ in raw }, batchHistory: history)
        workspace.importReport(project.appendingPathComponent("examples/after.audit.json")); try await settle(workspace)
        let identity = workspace.report?.image.sliceSHA256
        workspace.discoverBundle(root); try await settle(workspace)
        XCTAssertTrue(workspace.showingError); XCTAssertEqual(workspace.report?.image.sliceSHA256, identity)
        workspace.showingError = false; workspace.discoverBundle(app); try await settle(workspace)
        let row = try XCTUnwrap(workspace.bundleDiscovery?.entries.first(where: \.selectable))
        workspace.analyzeDiscoveredImages([row.id]); try await settle(workspace)
        let first = try XCTUnwrap(workspace.batchSnapshot)
        workspace.discoverBundle(app); try await settle(workspace)
        let secondRow = try XCTUnwrap(workspace.bundleDiscovery?.entries.first(where: \.selectable))
        workspace.analyzeDiscoveredImages([secondRow.id]); try await settle(workspace)
        let second = try XCTUnwrap(workspace.batchSnapshot)
        let plan = try BatchComparisonPlan(baseline: first, current: second)
        let result = try await BatchComparisonRunner().run(plan: plan, pairs: [], load: { try await library.load($0) }, compare: { _, _ in throw CocoaError(.fileReadUnknown) })
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: result.exportData()) as? [String: Any])
        let rows = try XCTUnwrap(exported["rows"] as? [[String: Any]])
        let current = try XCTUnwrap(rows[0]["current"] as? [String: Any]); XCTAssertNotNil(current["bundle_provenance"] as? [String: Any])
        XCTAssertThrowsError(try workspace.validateExportDestination(app.appendingPathComponent("report.json"), protectedInputs: [app]))
    }
}
