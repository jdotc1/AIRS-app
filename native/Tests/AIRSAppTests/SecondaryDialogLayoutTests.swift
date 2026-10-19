import AppKit
import SwiftUI
import XCTest
@testable import AIRSApp

/// New presentation inputs only: no source inspection, engine jobs or existing-suite replay.
final class SecondaryDialogLayoutTests: XCTestCase {
    @MainActor
    func testSecondaryDialogsFitTheirMinimumSizesInBothAppearances() throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/secondary-ui-review/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cases: [(String, AnyView, NSSize)] = [
            ("settings", AnyView(EngineSettingsView(workspace: AuditWorkspace())), NSSize(width: 640, height: 680)),
            ("find", AnyView(FindEntitlementView(find: { _, _ in .missing }, cancel: {})), NSSize(width: 480, height: 300)),
            ("focused", AnyView(FocusedValueView(selection: FocusedValueSelection(entitlementKey: "example.key", pathPreview: "example.key", previous: .string("Previous value"), current: .string("Current value")), actions: EntitlementsWorkspace())), NSSize(width: 880, height: 800))
        ]
        for dark in [false, true] {
            for (name, view, size) in cases {
                let label = name + (dark ? "-dark" : "-light")
                let host = NSHostingView(rootView: view.preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.setContentSize(size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, label)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1, label)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(label + ".png"), options: .withoutOverwriting)
                window.close()
            }
        }
    }
}
