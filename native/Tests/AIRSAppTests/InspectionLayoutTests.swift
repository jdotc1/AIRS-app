import AppKit
import SwiftUI
import XCTest
import AIRSEntitlements
import EntitlementDiffCore
import EntitlementDiffModel
@testable import AIRSApp

final class InspectionLayoutTests: XCTestCase {
    @MainActor
    func testStandaloneFitsMinimumWorkspaceAfterBoundsFix() throws {
        let workspace = EntitlementsWorkspace()
        workspace.model.useSavedBaseline(ExampleSnapshots.structuredPair(architecture: .arm64).previous)
        try render(workspace)
    }
    @MainActor
    func testCapturedStandaloneFitsMinimumWithCaptureControls() async throws {
        let workspace = EntitlementsWorkspace(reader: LayoutSnapshotReader())
        await workspace.inspect(URL(fileURLWithPath: "/Layout.app"), side: .previous)?.value
        XCTAssertNotNil(workspace.inspectionContexts[.previous])
        try render(workspace)
    }
    @MainActor
    private func render(_ workspace: EntitlementsWorkspace) throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/inspection-layout/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for standalone in [true] {
            let navigation = AIRSNavigation()
            navigation.showsEntitlements = true
            let host = NSHostingView(rootView: AIRSWindowView(audit: AuditWorkspace(), entitlements: workspace,
                navigation: navigation, fileOpen: AIRSFileOpen(hasModal: { false })))
            let size = NSSize(width: 1000, height: 660)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled,.resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.setContentSize(size)
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(standalone ? "standalone.png" : "comparison.png"))
            window.close()
        }
    }
}

private struct LayoutSnapshotReader: SnapshotReading {
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        ExampleSnapshots.structuredPair(architecture: architecture).previous
    }
}
