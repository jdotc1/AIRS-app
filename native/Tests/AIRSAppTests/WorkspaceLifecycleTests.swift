import Foundation
import XCTest
@testable import AIRSApp

final class WorkspaceLifecycleTests: XCTestCase {
    @MainActor
    func testQuitWaitsForExportAndFailureKeepsApplicationUsable() async throws {
        let workspace = AuditWorkspace()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = directory.appendingPathComponent("missing/result.json")
        workspace.exportJSON(Data("{}".utf8), to: missing)
        XCTAssertTrue(workspace.isBusy)
        XCTAssertFalse(workspace.canCancel)
        let shouldQuit = await workspace.finishBeforeQuit()
        XCTAssertFalse(shouldQuit)
        XCTAssertTrue(workspace.showingError)
        XCTAssertFalse(workspace.isBusy)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("result.json")
        workspace.exportJSON(Data("{}".utf8), to: destination)
        let nextQuit = await workspace.finishBeforeQuit()
        XCTAssertTrue(nextQuit)
        XCTAssertEqual(try Data(contentsOf: destination), Data("{}".utf8))
        XCTAssertFalse(workspace.isBusy)
    }
}
