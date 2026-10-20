import XCTest
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

private actor ArchitectureRecorder: SnapshotReading {
    var calls: [(URL, Architecture)] = []
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls.append((url, architecture))
        if url.lastPathComponent == "Missing.app", architecture == .x86_64 { throw CocoaError(.fileReadUnsupportedScheme) }
        return ExampleSnapshots.pair(architecture: architecture).previous
    }
    func recorded() -> [(URL, Architecture)] { calls }
}
final class ArchitectureSelectionTests: XCTestCase {
    @MainActor
    func testLiveURLsAreRereadWithoutReselection() async throws {
        let reader = ArchitectureRecorder()
        let workspace = EntitlementsWorkspace(reader: reader)
        let a = URL(fileURLWithPath: "/A.app"), b = URL(fileURLWithPath: "/B.app")
        await workspace.inspect(a, side: .previous)?.value
        await workspace.inspect(b, side: .current)?.value
        workspace.setArchitecture(.x86_64)
        await workspace.waitForSettlement()
        let calls = await reader.recorded()
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(Set(calls.suffix(2).map(\.0)), Set([a,b]))
        XCTAssertTrue(calls.suffix(2).allSatisfy { $0.1 == .x86_64 })
        XCTAssertEqual(workspace.model.previous.snapshot?.architecture, .x86_64)
        XCTAssertEqual(workspace.inspectionContexts[.current]?.document.snapshot.architecture, .x86_64)
    }
    @MainActor
    func testSavedBaselineLocksArchitectureWithoutDataLoss() {
        let workspace = EntitlementsWorkspace()
        workspace.model.useSavedBaseline(ExampleSnapshots.pair(architecture: .arm64).previous)
        let revision = workspace.model.reportRevision
        workspace.setArchitecture(.x86_64)
        XCTAssertEqual(workspace.model.architecture, .arm64)
        XCTAssertEqual(workspace.model.reportRevision, revision)
        XCTAssertFalse(workspace.canChangeArchitecture)
    }
    @MainActor
    func testMissingRequestedSliceDoesNotFallback() async throws {
        let reader = ArchitectureRecorder()
        let workspace = EntitlementsWorkspace(reader: reader)
        await workspace.inspect(URL(fileURLWithPath: "/Missing.app"), side: .previous)?.value
        workspace.setArchitecture(.x86_64)
        await workspace.waitForSettlement()
        XCTAssertNil(workspace.model.previous.snapshot)
        XCTAssertNil(workspace.inspectionContexts[.previous])
        XCTAssertEqual(workspace.model.architecture, .x86_64)
        let calls = await reader.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.1, .x86_64)
    }
}
