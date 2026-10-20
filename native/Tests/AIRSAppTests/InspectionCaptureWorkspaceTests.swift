import XCTest
import AIRSEntitlements
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

private struct CaptureReader: SnapshotReading {
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent == "A.app" ? pair.previous : pair.current
    }
}

final class InspectionCaptureWorkspaceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor
    func testCaptureSurvivesOriginalAppRemoval() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = InspectionLibrary(root: root.appendingPathComponent("store"))
        let workspace = EntitlementsWorkspace(reader: CaptureReader(), inspectionLibrary: library)
        let app = root.appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        await workspace.inspect(app, side: .previous)?.value
        let context = try XCTUnwrap(workspace.inspectionContexts[.previous])
        await workspace.captureBaseline(.previous, label: "Before upgrade")?.value
        try FileManager.default.removeItem(at: app)
        let fresh = EntitlementsWorkspace(inspectionLibrary: library)
        await fresh.openInspectionLibrary()?.value
        let entry = try XCTUnwrap(fresh.inspectionEntries.first)
        XCTAssertEqual(entry.sourceLabel, "Before upgrade")
        await fresh.reviewInspection(entry.id)?.value
        XCTAssertEqual(fresh.inspectionReview?.data, context.data)
        fresh.adoptInspection(.useAsPrevious)
        XCTAssertTrue(try XCTUnwrap(fresh.model.previous.snapshot).isSavedBaseline)
        XCTAssertTrue(fresh.model.selectedSourceURLs.isEmpty)
        XCTAssertEqual(fresh.inspectionContexts[.previous]?.document.capturedAt, context.document.capturedAt)
        XCTAssertEqual(fresh.model.previous.snapshot?.entitlements, context.document.snapshot.entitlements)
    }
    @MainActor
    func testSwapCarriesCaptureContextsWithInputs() async throws {
        let workspace = EntitlementsWorkspace(reader: CaptureReader())
        await workspace.inspect(URL(fileURLWithPath: "/A.app"), side: .previous)?.value
        await workspace.inspect(URL(fileURLWithPath: "/B.app"), side: .current)?.value
        let previous = try XCTUnwrap(workspace.inspectionContexts[.previous])
        let current = try XCTUnwrap(workspace.inspectionContexts[.current])
        workspace.swap()
        XCTAssertEqual(workspace.inspectionContexts[.previous]?.id, current.id)
        XCTAssertEqual(workspace.inspectionContexts[.current]?.id, previous.id)
        XCTAssertEqual(workspace.model.previous.snapshot?.entitlements, current.document.snapshot.entitlements)
    }
    @MainActor
    func testFailedCapturePreservesDisplayedComparison() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = EntitlementsWorkspace(reader: CaptureReader(), inspectionLibrary: InspectionLibrary(root: root, maximumEntries: 0))
        await workspace.inspect(URL(fileURLWithPath: "/A.app"), side: .previous)?.value
        await workspace.inspect(URL(fileURLWithPath: "/B.app"), side: .current)?.value
        let revision = workspace.model.reportRevision
        await workspace.captureBaseline(.previous, label: "No space")?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertNotNil(workspace.model.report)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertFalse(workspace.requiresQuitSettlement)
    }
    @MainActor
    func testImportedCaptureRetainsOriginalWhitespaceBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let document = try InspectionDocument(snapshot: ExampleSnapshots.pair(architecture: .arm64).previous,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")
        var data = Data(" \n".utf8); data.append(try InspectionDocumentCodec.encode(document)); data.append(Data(" \n".utf8))
        let imported = try InspectionDocumentCodec.decode(data)
        let library = InspectionLibrary(root: root.appendingPathComponent("store"))
        let workspace = EntitlementsWorkspace(inspectionLibrary: library)
        let source = root.appendingPathComponent("original.airsinspect")
        try data.write(to: source)
        workspace.reviewValidatedInspection(imported, data: data, from: source)
        workspace.adoptInspection(.inspect)
        let output = root.appendingPathComponent("export.airsinspect")
        await workspace.exportInspection(.previous, to: output)?.value
        XCTAssertEqual(try Data(contentsOf: output), data)
        await workspace.captureBaseline(.previous, label: "Imported")?.value
        let retained = try await library.load(XCTUnwrap(workspace.inspectionEntries.first).id)
        XCTAssertEqual(retained.data, data)
        await workspace.exportInspection(.previous, to: source)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
    @MainActor
    func testLegacyImportHasUnknownCaptureMetadata() throws {
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let saved = try SavedReport.parse(EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current).jsonData())
        let workspace = EntitlementsWorkspace()
        workspace.reviewValidatedReport(saved, from: URL(fileURLWithPath: "/old.json"))
        workspace.openSavedComparison()
        XCTAssertTrue(workspace.inspectionContexts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(workspace.model.previous.snapshot).isSavedBaseline)
    }
}

private actor CaptureGate: SnapshotReading {
    private var pending: CheckedContinuation<EntitlementSnapshot, Error>?
    private var observer: CheckedContinuation<Void, Never>?
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        if architecture == .arm64 { return ExampleSnapshots.pair(architecture: architecture).previous }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation; observer?.resume(); observer = nil
        }
    }
    func started() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish() { pending?.resume(returning: ExampleSnapshots.pair(architecture: .x86_64).previous); pending = nil }
}

extension InspectionCaptureWorkspaceTests {
    @MainActor
    func testLateReadCannotAttachCaptureToReplacement() async throws {
        let gate = CaptureGate()
        let workspace = EntitlementsWorkspace(reader: gate)
        workspace.setArchitecture(.x86_64)
        let read = try XCTUnwrap(workspace.inspect(URL(fileURLWithPath: "/Late.app"), side: .previous))
        await gate.started()
        // Exercise the donor generation guard even if another owner replaces state.
        workspace.model.useSavedBaseline(ExampleSnapshots.pair(architecture: .arm64).current)
        await gate.finish(); await read.value
        XCTAssertNil(workspace.inspectionContexts[.previous], "A late native job must not capture a replacement saved snapshot")
        XCTAssertEqual(workspace.model.previous.snapshot?.architecture, .arm64)
    }
    @MainActor
    func testCancelledArchitectureReloadCannotPublishOldSlice() async throws {
        let gate = CaptureGate()
        let workspace = EntitlementsWorkspace(reader: gate)
        await workspace.inspect(URL(fileURLWithPath: "/A.app"), side: .previous)?.value
        workspace.setArchitecture(.x86_64)
        await gate.started()
        workspace.cancel()
        XCTAssertTrue(workspace.requiresQuitSettlement)
        await gate.finish(); await workspace.waitForSettlement()
        XCTAssertNil(workspace.model.previous.snapshot)
        XCTAssertTrue(workspace.inspectionContexts.isEmpty)
        XCTAssertFalse(workspace.requiresQuitSettlement)
    }
}

extension InspectionCaptureWorkspaceTests {
    @MainActor
    func testAllExportsProtectImportedDocumentAndInspectionLibrary() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("InspectionLibrary")
        let workspace = EntitlementsWorkspace(reader: CaptureReader(), inspectionLibrary: InspectionLibrary(root: store))
        let document = try InspectionDocument(snapshot: ExampleSnapshots.pair(architecture: .arm64).previous,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")
        let bytes = try InspectionDocumentCodec.encode(document)
        let source = root.appendingPathComponent("source.airsinspect")
        try bytes.write(to: source)
        workspace.reviewValidatedInspection(try InspectionDocumentCodec.decode(bytes), data: bytes, from: source)
        workspace.adoptInspection(.useAsPrevious)
        await workspace.inspect(URL(fileURLWithPath: "/B.app"), side: .current)?.value
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        for output in [source, store.appendingPathComponent("bad.json")] {
            for kind in 0..<3 {
                workspace.errorMessage = nil
                let task: Task<Void, Never>?
                switch kind {
                case 0: task = workspace.export(to: output)
                case 1: task = workspace.exportText(to: output)
                default: task = workspace.exportInspection(.previous, to: output)
                }
                await task?.value
                XCTAssertNotNil(workspace.errorMessage)
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
        }
    }
    @MainActor
    func testMissingPinnedBaselineClearsDefaultVisibly() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("InspectionLibrary")
        let preferences = root.appendingPathComponent("InspectionPreferences.json")
        try InspectionLibraryPreferences(pinnedBaselineID: UUID()).write(to: preferences)
        let workspace = EntitlementsWorkspace(inspectionLibrary: InspectionLibrary(root: store))
        await workspace.openInspectionLibrary()?.value
        XCTAssertNil(workspace.pinnedInspectionID)
        XCTAssertNil(try InspectionLibraryPreferences.read(at: preferences).pinnedBaselineID)
        XCTAssertTrue(workspace.status.contains("unavailable"))
    }
}

extension InspectionCaptureWorkspaceTests {
    @MainActor
    func testFailedPinWriteLeavesPreviousDefaultIntact() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InspectionLibrary(root: root.appendingPathComponent("InspectionLibrary"))
        let document = try InspectionDocument(snapshot: ExampleSnapshots.pair(architecture: .arm64).previous,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")
        let first = try await store.keep(document, label: "First")
        let second = try await store.keep(document, label: "Second")
        let url = root.appendingPathComponent("InspectionPreferences.json")
        try InspectionLibraryPreferences(pinnedBaselineID: first).write(to: url)
        let workspace = EntitlementsWorkspace(inspectionLibrary: store, writeInspectionPreferences: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        await workspace.openInspectionLibrary()?.value
        await workspace.pinInspection(second)?.value
        XCTAssertNotNil(workspace.errorMessage)
        XCTAssertEqual(workspace.pinnedInspectionID, first)
        XCTAssertEqual(try InspectionLibraryPreferences.read(at: url).pinnedBaselineID, first)
    }
}

extension InspectionCaptureWorkspaceTests {
    @MainActor
    func testBaselineLibraryCannotHideOtherDestinationsOrFind() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = EntitlementsWorkspace(library: EntitlementReportLibrary(root: root.appendingPathComponent("reports")),
            batchHistory: EntitlementBatchHistory(root: root.appendingPathComponent("history")),
            inspectionLibrary: InspectionLibrary(root: root.appendingPathComponent("inspections")))
        workspace.loadExample()
        await workspace.openInspectionLibrary()?.value
        XCTAssertFalse(workspace.canFindEntitlement)
        workspace.openBatch()
        XCTAssertFalse(workspace.showingInspectionLibrary)
        XCTAssertTrue(workspace.showingBatch)
        await workspace.openInspectionLibrary()?.value
        await workspace.openBatchHistory()?.value
        XCTAssertFalse(workspace.showingInspectionLibrary)
        XCTAssertTrue(workspace.showingBatchHistory)
        await workspace.openInspectionLibrary()?.value
        await workspace.openBatchRecovery()?.value
        XCTAssertFalse(workspace.showingInspectionLibrary)
        XCTAssertTrue(workspace.showingBatchRecovery)
    }
}

extension InspectionCaptureWorkspaceTests {
    @MainActor
    func testUnchangedRetainedComparisonAndRemovalPreserveActiveEvidence() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = InspectionLibrary(root: root.appendingPathComponent("InspectionLibrary"))
        let workspace = EntitlementsWorkspace(reader: CaptureReader(), inspectionLibrary: store)
        await workspace.inspect(URL(fileURLWithPath: "/A.app"), side: .previous)?.value
        await workspace.captureBaseline(.previous, label: "Before")?.value
        let id = try XCTUnwrap(workspace.inspectionEntries.first?.id)
        await workspace.pinInspection(id)?.value
        await workspace.reviewInspection(id)?.value
        workspace.adoptInspection(.useAsPrevious)
        await workspace.inspect(URL(fileURLWithPath: "/A.app"), side: .current)?.value
        let report = try XCTUnwrap(workspace.model.report)
        XCTAssertTrue(report.changes.isEmpty)
        XCTAssertEqual(report.unchangedCount, report.previous.entitlements.entries.count)
        let revision = workspace.model.reportRevision
        let raw = workspace.inspectionContexts[.previous]?.data
        await workspace.removeInspection(id)?.value
        XCTAssertTrue(workspace.inspectionEntries.isEmpty)
        XCTAssertNil(workspace.pinnedInspectionID)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertEqual(workspace.inspectionContexts[.previous]?.data, raw)
        XCTAssertTrue(workspace.model.previous.snapshot?.isSavedBaseline == true)
    }
}
