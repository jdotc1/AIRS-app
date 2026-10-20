import Foundation
import XCTest
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

private struct TextExportFixtureReader: SnapshotReading {
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent == "Previous.app" ? pair.previous : pair.current
    }
}

private actor TextExportGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        try await withCheckedThrowingContinuation {
            continuation = $0
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

final class EntitlementTextExportTests: XCTestCase {
    @MainActor
    func testTextExportMatchesTheCompleteSerializerDespiteAnEmptyFilter() async throws {
        let workspace = EntitlementsWorkspace(reader: TextExportFixtureReader())
        let privateSourceRoot = "/fixtures/private-release-folder"
        await workspace.inspect(URL(fileURLWithPath: privateSourceRoot + "/Previous.app"), side: .previous)?.value
        await workspace.inspect(URL(fileURLWithPath: privateSourceRoot + "/Current.app"), side: .current)?.value
        let report = try XCTUnwrap(workspace.model.report)
        workspace.model.browser.query = "no-key-matches-this-filter"
        XCTAssertTrue(workspace.model.browser.visibleRows.isEmpty)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("comparison.txt")
        await workspace.exportText(to: output)?.value
        XCTAssertNil(workspace.errorMessage)
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(bytes, Data(InspectionSummary.text(report: report, contexts: workspace.inspectionContexts).utf8))
        XCTAssertEqual(workspace.model.browser.query, "no-key-matches-this-filter")
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(directory.path))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(privateSourceRoot))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("unchanged keys:"))
    }

    func testTextWriterRefusesAnInputBundleAndItsSymlinkAlias() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Original.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let alias = directory.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let report = try EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current)
        for parent in [source, alias] {
            let output = parent.appendingPathComponent("report.txt")
            do {
                try await EntitlementsWorkspace.writeTextSaved(report, output, [source])
                XCTFail("An output inside an inspected app must be rejected")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    @MainActor
    func testTextExportUsesWriteSettlementAndDoesNotAllowCancellationDuringPublication() async throws {
        let gate = TextExportGate()
        let workspace = EntitlementsWorkspace(writeTextReport: { _, _, _ in try await gate.wait() })
        workspace.loadExample()
        let task = try XCTUnwrap(workspace.exportText(to: URL(fileURLWithPath: "/unused.txt")))
        await gate.started()
        XCTAssertTrue(workspace.isWriting)
        XCTAssertTrue(workspace.isWorking)
        XCTAssertFalse(workspace.canCancel)
        XCTAssertTrue(workspace.requiresQuitSettlement)
        workspace.cancel()
        XCTAssertTrue(workspace.isWorking)
        await gate.finish()
        await task.value
        XCTAssertFalse(workspace.isWriting)
        XCTAssertFalse(workspace.isWorking)
    }

    @MainActor
    func testTextWriteFailureIsVisibleAndVetoesTheFirstQuitAttempt() async throws {
        let workspace = EntitlementsWorkspace(writeTextReport: { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        workspace.loadExample()
        let reportRevision = workspace.model.reportRevision
        await workspace.exportText(to: URL(fileURLWithPath: "/unused.txt"))?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(workspace.model.reportRevision, reportRevision)
        let ready = await workspace.finishBeforeQuit()
        XCTAssertFalse(ready)
        XCTAssertFalse(workspace.isTerminating)
    }

    @MainActor
    func testStandaloneInputDoesNotExportAComparisonSummary() {
        let workspace = EntitlementsWorkspace()
        workspace.model.useSavedBaseline(ExampleSnapshots.pair(architecture: .arm64).previous)
        XCTAssertNotNil(workspace.standaloneInspection)
        XCTAssertNil(workspace.exportText(to: URL(fileURLWithPath: "/unused.txt")))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
