import AppKit
import SwiftUI
import EntitlementDiffCore

/// Receives only one bounded escaped page. Match styling never edits source or clipboard values.
struct HighlightedStringPageView: NSViewRepresentable {
    private let value: String
    private let highlight: NSRange?
    let pageIndex: Int
    let revealRevision: UUID?

    init(page: LeafValueDocument.StringPage, pageIndex: Int, revealRevision: UUID?) {
        value = page.text; highlight = page.highlight
        self.pageIndex = pageIndex; self.revealRevision = revealRevision
    }

    /// Base64 and other already-formatted bounded pages use the same literal, selectable renderer.
    init(text: String, pageIndex: Int, revealRevision: UUID?) {
        value = text; highlight = nil
        self.pageIndex = pageIndex; self.revealRevision = revealRevision
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }
    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // The scroll view begins at zero size. A nonzero placeholder document width
        // is added to the first clip-view resize in a presented SwiftUI sheet,
        // leaving text wrapped hundreds of points beyond the visible pane.
        let text = PageTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineBreakMode = .byCharWrapping
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? PageTextView else { return }
        context.coordinator.update(text, value: value, highlight: highlight, pageIndex: pageIndex, revision: revealRevision)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        (view.documentView as? PageTextView)?.pendingReveal = nil
    }
    @MainActor
    final class Coordinator {
        private var pageIndex: Int?
        private var revision: UUID?
        private var previousText: String?
        private var previousHighlight: NSRange?
        func update(_ text: PageTextView, value: String, highlight: NSRange?, pageIndex: Int, revision: UUID?) {
            let changedPage = self.pageIndex != pageIndex
            let reveal = changedPage || self.revision != revision
            if previousText?.utf8.elementsEqual(value.utf8) != true || previousHighlight != highlight {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byCharWrapping
                paragraph.hyphenationFactor = 0
                paragraph.usesDefaultHyphenation = false
                paragraph.lineBreakStrategy = []
                let display = NSMutableAttributedString(string: value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                    .paragraphStyle: paragraph
                ])
                if let range = highlight {
                    display.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor,
                                           .foregroundColor: NSColor.selectedTextColor], range: range)
                }
                text.textStorage?.setAttributedString(display)
            }
            if reveal, let range = highlight {
                text.pendingReveal = range
            } else if changedPage {
                text.pendingReveal = NSRange(location: 0, length: 0)
            } else if highlight == nil {
                text.pendingReveal = nil
            }
            self.pageIndex = pageIndex
            self.revision = revision
            previousText = value
            previousHighlight = highlight
            text.needsLayout = true
        }
    }
    final class PageTextView: NSTextView {
        var pendingReveal: NSRange?
        override func layout() {
            super.layout()
            guard bounds.width > 0, let range = pendingReveal, let container = textContainer else { return }
            pendingReveal = nil
            layoutManager?.ensureLayout(for: container)
            // Reveal the beginning even when the match spans more than the viewport.
            scrollRangeToVisible(NSRange(location: range.location, length: min(1, range.length)))
        }
    }
}
