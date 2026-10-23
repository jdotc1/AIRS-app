import AppKit
import SwiftUI
import LumenUI
import XCTest
import AIRSCore
@testable import AIRSApp

final class ComparisonSheetLayoutTests: XCTestCase {
    /// Native sheet sizing, deliberately separate from report/engine qualification.
    @MainActor
    func testPresentationSizingAndDismissalWithIsolatedStores() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temporary = root.appendingPathComponent("build/comparison-sheet-layout/\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let suite = "dev.airs.comparison-layout.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        let workspace = AuditWorkspace(recents: SettingsReviewRecents(), supportRoot: temporary,
                                       preferences: preferences)
        workspace.importReport(root.appendingPathComponent("examples/before.audit.json"))
        for _ in 0..<100 {
            if !workspace.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(workspace.report)
        let original = try Data(contentsOf: root.appendingPathComponent("examples/before-after.diff.json"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        // Synthetic empty-filter layout matches the captured unchanged-only sheet.
        // These display inputs do not assert new engine or comparison evidence.
        payload["changes"] = []
        payload["summary"] = ["matched_count": 3, "changed_count": 0, "unchanged_count": 3,
                              "added_count": 0, "removed_count": 0, "ambiguous_count": 0]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let document = ComparisonDocument(report: try ComparisonReport.decode(data), data: data,
                                           formattedJSON: String(decoding: data, as: UTF8.self))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WorkspaceView(workspace: workspace)
            .lumenPaletteRoot().lumenMetrics(.standard).lumenDensityRoot())
        // Order behind existing windows; never activate or make this window key.
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.comparisonDocument = document
        try await Task.sleep(nanoseconds: 400_000_000)
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.isVisible)
        XCTAssertGreaterThanOrEqual(sheet.frame.width, 780)
        XCTAssertGreaterThanOrEqual(sheet.frame.height, 600)
        sheet.setContentSize(NSSize(width: 780, height: 600))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sheet.frame.width.isFinite && sheet.frame.height.isFinite)
        workspace.comparisonDocument = nil
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(workspace.comparisonDocument)
    }
}

final class ComparisonChangePageTests: XCTestCase {
    func testEveryFindingRemainsReachableExactlyOnceAcrossBoundedPages() {
        for count in [0, 1, 49, 50, 51, 103] {
            let first = ComparisonChangePage(count: count, index: 0)
            let ranges = (0..<first.pageCount).map { ComparisonChangePage(count: count, index: $0).range }
            XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<count))
            XCTAssertTrue(ranges.allSatisfy { $0.count <= 50 })
        }
    }

    func testShrinkingFilterClampsOldPageWithoutDroppingRemainingFindings() {
        let filtered = ComparisonChangePage(count: 1, index: 2)
        XCTAssertEqual(filtered.index, 0)
        XCTAssertEqual(filtered.range, 0..<1)
        XCTAssertTrue(ComparisonChangePage(count: 0, index: 2).range.isEmpty)
        XCTAssertEqual(ComparisonChangePage(count: 51, index: -1).range, 0..<50)
    }
}
