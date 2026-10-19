import AppKit
import SwiftUI
import XCTest
@testable import AIRSApp

final class FocusedTextViewportTests: XCTestCase {
    @MainActor
    func testPresentedSheetKeepsWrappedTextInsideItsVisiblePane() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FocusedTextSheetFixture())
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        func panes(_ view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).flatMap {
                $0.documentView is HighlightedStringPageView.PageTextView ? $0 : nil
            }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap(panes)
        }
        var scrolls: [NSScrollView] = []
        for _ in 0..<10 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            scrolls = window.attachedSheet?.contentView.map(panes) ?? []
            if scrolls.count == 2 { break }
        }
        XCTAssertEqual(scrolls.count, 2, "Review the actual presented sheet, not a detached scroll view")
        for scroll in scrolls {
            let text = try XCTUnwrap(scroll.documentView as? NSTextView)
            let container = try XCTUnwrap(text.textContainer)
            let layout = try XCTUnwrap(text.layoutManager)
            layout.ensureLayout(for: container)
            XCTAssertEqual(text.frame.width, scroll.contentSize.width, accuracy: 0.5,
                           "Initial native sheet layout must not add a phantom document width")
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX + text.textContainerOrigin.x,
                                     scroll.documentVisibleRect.maxX + 0.5,
                                     "All wrapped glyphs must fit within the visible pane")
        }
    }
    @MainActor
    func testPlainDataPageKeepsExactBytesAndClearsPriorHighlight() throws {
        let scroll = HighlightedStringPageView.makeScrollView()
        scroll.setFrameSize(NSSize(width: 300, height: 160))
        let text = try XCTUnwrap(scroll.documentView as? HighlightedStringPageView.PageTextView)
        let coordinator = HighlightedStringPageView.Coordinator()
        coordinator.update(text, value: "previous string page", highlight: NSRange(location: 0, length: 8),
                           pageIndex: 0, revision: UUID())
        let encoded = Data((0..<768).map { UInt8($0 % 256) }).base64EncodedString()
        coordinator.update(text, value: encoded, highlight: nil, pageIndex: 1, revision: UUID())
        XCTAssertEqual(text.string, encoded, "The displayed base64 page must remain byte-for-byte literal")
        XCTAssertNil(text.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                     "A previous string match must not remain highlighted on a plain data page")
        let container = try XCTUnwrap(text.textContainer)
        text.layoutManager?.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(text.layoutManager?.usedRect(for: container).maxX ?? .infinity,
                                 scroll.contentSize.width - 2 * text.textContainerInset.width + 0.5)
    }

}

@MainActor
private struct FocusedTextSheetFixture: View {
    @State private var presented = false
    @State private var actions = EntitlementsWorkspace()
    private let selection = FocusedValueSelection(entitlementKey: "example.review", pathPreview: "Value",
        previous: .string(String(repeating: "0123456789 ", count: 80) + "PREVIOUS END"),
        current: .string(String(repeating: "0123456789 ", count: 80) + "CURRENT END"))
    var body: some View {
        Text("Native sheet fixture").frame(minWidth: 1000, minHeight: 660)
            .onAppear { presented = true }
            .sheet(isPresented: $presented) { FocusedValueView(selection: selection, actions: actions) }
    }
}
