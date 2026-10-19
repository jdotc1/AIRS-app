import Darwin
import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

@MainActor
private final class BatchRecentsSpy: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
    func clearRecentDocuments() { recentDocumentURLs = [] }
}

private struct OwnedBatchFixture: Sendable {
    let root: URL
    let inputs: [URL]
    let raw: Data
    let configuration: EngineConfiguration
    var pidFile: URL { root.appendingPathComponent("slow.pid") }
    var libraryURL: URL { root.appendingPathComponent("library") }
    var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent("build/batch-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureRoot = root
        inputs = ["01 complete; 'owned'.input", "02 slow.input", "03 pending.input"].map { fixtureRoot.appendingPathComponent($0) }
        for input in inputs { try Data("Owned data placeholder; never executed".utf8).write(to: input) }
        raw = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        try raw.write(to: root.appendingPathComponent("saved.audit.json"))
        let script = root.appendingPathComponent("owned_batch_bootstrap.py")
        try """
        import os, pathlib, sys, time
        root = pathlib.Path(__file__).parent
        args = sys.argv[1:]
        source = pathlib.Path(args[-1])
        if source.name.startswith('02'):
            (root / 'slow.pid').write_text(str(os.getpid()))
            time.sleep(30)
        output = pathlib.Path(args[args.index('--output') + 1])
        output.write_bytes((root / 'saved.audit.json').read_bytes())
        """.write(to: script, atomically: true, encoding: .utf8)
        configuration = EngineConfiguration(pythonExecutable: try EngineConfiguration.resolve(pythonSetting: "").pythonExecutable,
                                            bootstrap: script)
    }
}

final class ImageBatchWorkspaceTests: XCTestCase {
    @MainActor
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned batch workspace operation did not settle")
    }

    @MainActor
    func testOwnedChildCancellationRetainsCompletedReportAndAllowsNextBatch() async throws {
        let fixture = try OwnedBatchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let library = ReportLibrary(root: fixture.libraryURL)
        let runner = EngineRunner()
        let workspace = AuditWorkspace(library: library, recents: BatchRecentsSpy(), batchAudit: { input in
            try await runner.run(.audit(input: input), configuration: fixture.configuration).data
        })
        workspace.importReport(fixture.project.appendingPathComponent("examples/after.audit.json"))
        try await waitFor { !workspace.isBusy }
        let original = try XCTUnwrap(workspace.report)
        workspace.startBatch(fixture.inputs)
        try await waitFor { FileManager.default.fileExists(atPath: fixture.pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.pidFile, encoding: .utf8)))
        workspace.cancel()
        try await waitFor { !workspace.isBusy }
        let snapshot = try XCTUnwrap(workspace.batchSnapshot)
        XCTAssertEqual(snapshot.items.map(\.status), [.completed, .cancelled, .notStarted])
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, original.image.sliceSHA256)
        let kept = try await library.load(XCTUnwrap(snapshot.items[0].retainedReportID))
        XCTAssertEqual(kept.data, fixture.raw)
        XCTAssertEqual(kept.provenance.inspectedInput, fixture.inputs[0])
        workspace.startBatch([fixture.inputs[0]])
        try await waitFor { !workspace.isBusy }
        XCTAssertNotEqual(workspace.batchSnapshot?.id, snapshot.id)
        XCTAssertEqual(workspace.batchSnapshot?.items.map(\.status), [.completed])
        XCTAssertEqual(workspace.report?.image.sliceSHA256, original.image.sliceSHA256)
        let item = try XCTUnwrap(workspace.batchSnapshot?.items.first)
        workspace.openBatchReport(item)
        try await waitFor { !workspace.isBusy }
        XCTAssertFalse(workspace.showingBatch)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, kept.report.image.sliceSHA256)
    }

    @MainActor
    func testOrdinaryQuitSettlesActiveBatchAndRetainsEarlierCompletion() async throws {
        let fixture = try OwnedBatchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let library = ReportLibrary(root: fixture.libraryURL); let runner = EngineRunner()
        let workspace = AuditWorkspace(library: library, recents: BatchRecentsSpy(), batchAudit: { input in
            try await runner.run(.audit(input: input), configuration: fixture.configuration).data
        })
        workspace.startBatch(fixture.inputs)
        try await waitFor { FileManager.default.fileExists(atPath: fixture.pidFile.path) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.pidFile, encoding: .utf8)))
        let quit = await workspace.finishBeforeQuit()
        XCTAssertTrue(quit)
        XCTAssertFalse(workspace.isBusy)
        XCTAssertEqual(workspace.batchSnapshot?.items.map(\.status), [.completed, .cancelled, .notStarted])
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
    }

    @MainActor
    func testRetentionFailureBlocksQuitAndSuccessfulRetrySettlesBeforeQuit() async throws {
        let fixture = try OwnedBatchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.libraryURL)
        let library = ReportLibrary(root: fixture.libraryURL)
        let workspace = AuditWorkspace(library: library, recents: BatchRecentsSpy(), batchAudit: { _ in fixture.raw })
        workspace.startBatch(Array(fixture.inputs.prefix(2)))
        try await waitFor { !workspace.isBusy }
        XCTAssertEqual(workspace.batchSnapshot?.items.map(\.status), [.completed, .notStarted])
        XCTAssertTrue(workspace.requiresQuitSettlement)
        let firstQuit = await workspace.finishBeforeQuit()
        XCTAssertFalse(firstQuit)
        XCTAssertTrue(workspace.showingError)
        let item = try XCTUnwrap(workspace.batchSnapshot?.items.first)
        XCTAssertEqual(item.unretainedData, fixture.raw)
        let originalBatch = workspace.batchSnapshot?.id
        workspace.startBatch([fixture.inputs[2]])
        XCTAssertEqual(workspace.batchSnapshot?.id, originalBatch)
        workspace.retryBatchRetention(item)
        let failedRetryQuit = await workspace.finishBeforeQuit()
        XCTAssertFalse(failedRetryQuit)
        XCTAssertTrue(workspace.hasUnretainedBatchReports)
        try FileManager.default.removeItem(at: fixture.libraryURL)
        workspace.retryBatchRetention(item)
        XCTAssertTrue(workspace.isBusy)
        XCTAssertFalse(workspace.canCancel)
        let secondQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(secondQuit)
        XCTAssertFalse(workspace.hasUnretainedBatchReports)
        let retainedID = try XCTUnwrap(workspace.batchSnapshot?.items.first?.retainedReportID)
        let retained = try await library.load(retainedID)
        XCTAssertEqual(retained.data, fixture.raw)
    }

    @MainActor
    func testExplicitDiscardAllowsProgressWithoutDroppingAnotherInputOutcome() async throws {
        let fixture = try OwnedBatchFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data().write(to: fixture.libraryURL)
        let workspace = AuditWorkspace(library: ReportLibrary(root: fixture.libraryURL), recents: BatchRecentsSpy(), batchAudit: { _ in fixture.raw })
        workspace.startBatch(fixture.inputs)
        try await waitFor { !workspace.isBusy }
        let item = try XCTUnwrap(workspace.batchSnapshot?.items.first)
        workspace.discardBatchSessionCopy(item.id)
        XCTAssertFalse(workspace.hasUnretainedBatchReports)
        XCTAssertEqual(workspace.batchSnapshot?.items.count, 3)
        workspace.startBatch([fixture.root.appendingPathComponent("missing.input")])
        try await waitFor { !workspace.isBusy }
        XCTAssertEqual(workspace.batchSnapshot?.items.map(\.status), [.failed])
        let canQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(canQuit)
    }
}
