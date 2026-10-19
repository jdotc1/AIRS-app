import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

final class SourceWorkspaceTests: XCTestCase {
    @MainActor
    func testRejectedDSYMPreservesCurrentReportAndSelectedFinding() async throws {
        _ = try EngineConfiguration.resolve(pythonSetting: "")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspace = AuditWorkspace()
        workspace.importReport(root.appendingPathComponent("examples/before.audit.json"))
        try await settle(workspace)
        let original = try XCTUnwrap(workspace.report)
        let findingID = try XCTUnwrap(original.findings.first?.id)
        workspace.selection = .finding(findingID)
        workspace.attachDSYM(root.appendingPathComponent("build/absent-companion.dSYM"))
        try await settle(workspace)
        XCTAssertTrue(workspace.showingError)
        XCTAssertEqual(workspace.report?.image.sliceSHA256, original.image.sliceSHA256)
        XCTAssertEqual(workspace.report?.findings.map(\.id), original.findings.map(\.id))
        XCTAssertEqual(workspace.selectedFinding?.id, findingID)
        XCTAssertNil(workspace.report?.sourceAnnotations)
        XCTAssertTrue(workspace.errorMessage.contains("unavailable"))
    }

    @MainActor
    private func settle(_ workspace: AuditWorkspace) async throws {
        for _ in 0..<500 {
            if !workspace.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned source attachment did not settle within five seconds")
        workspace.cancel()
        _ = await workspace.finishBeforeQuit()
    }
}
