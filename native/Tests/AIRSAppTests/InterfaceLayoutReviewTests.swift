import AppKit
import SwiftUI
import XCTest
import AIRSCore
@testable import AIRSApp

/// Bounded review renders for the changed shell. No engine, app inspection or retained-data writes.
final class InterfaceLayoutReviewTests: XCTestCase {
    @MainActor
    func testEntitlementColumnsFitMinimumAndWideWorkspaces() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent("build/ui-overhaul/column-layout-review", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let variants: [(String, Bool, Bool, NSSize)] = [
            ("entitlements-values-dark-wide", true, true, NSSize(width: 1240, height: 800)),
            ("entitlements-values-dark-minimum", true, true, NSSize(width: 1000, height: 660))
        ]
        for (name, isEntitlements, populated, size) in variants {
            let audit = AuditWorkspace()
            let entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
            let fileOpen = AIRSFileOpen(hasModal: { false })
            navigation.showsEntitlements = isEntitlements
            if populated && isEntitlements {
                entitlements.loadExample(); entitlements.moveToChange(.next)
            } else if populated {
                let url = root.appendingPathComponent("examples/before.audit.json")
                let data = try Data(contentsOf: url)
                audit.openValidatedReport(try AuditReport.decode(data), data: data, from: url)
            }
            let dark = name.contains("dark")
            let view = AIRSWindowView(audit: audit, entitlements: entitlements,
                                      navigation: navigation, fileOpen: fileOpen)
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let fitting = host.fittingSize
            XCTAssertLessThanOrEqual(fitting.width, size.width + 1, name + " exceeds minimum window width")
            XCTAssertLessThanOrEqual(fitting.height, size.height + 1, name + " exceeds minimum window height")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
            window.close()
        }
    }
}
