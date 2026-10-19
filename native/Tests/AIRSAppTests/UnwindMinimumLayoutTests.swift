import AppKit
import SwiftUI
import XCTest
import AIRSCore
import LumenUI
@testable import AIRSApp

/// New bounded renders of the changed unwind workflow; no engine job or source-image inspection.
final class UnwindMinimumLayoutTests: XCTestCase {
    @MainActor
    func testChangedUnwindStatesFitMinimumWorkspace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reportURL = root.appendingPathComponent("examples/after.audit.json")
        let data = try Data(contentsOf: reportURL)
        let report = try AuditReport.decode(data)
        let finding = try XCTUnwrap(report.findings.first { $0.verdict == .inconsistency })
        let output = root.appendingPathComponent("build/unwind-review/layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let variants: [(String, Bool, Bool, Bool)] = [
            ("finding-light", false, false, false),
            ("hidden-finding-light", false, true, false),
            ("hidden-finding-dark", true, true, false),
            ("empty-overview-light", false, true, true)
        ]
        for (name, dark, hidden, overview) in variants {
            let audit = AuditWorkspace()
            audit.openValidatedReport(report, data: data, from: reportURL)
            audit.selection = overview ? .overview : .finding(finding.id)
            if hidden { audit.search = "no-such-function-for-layout-review" }
            let view = AIRSWindowView(audit: audit, entitlements: EntitlementsWorkspace(),
                                     navigation: AIRSNavigation(), fileOpen: AIRSFileOpen(hasModal: { false }))
                .lumenPaletteRoot(windowChrome: false)
                .lumenMetrics(.standard).lumenDensityRoot()
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let size = NSSize(width: 1000, height: 660)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, name)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1, name)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
            window.close()
        }
        print("UNWIND_LAYOUT_RECEIPTS \(output.path)")
    }
}
