import AppKit
import SwiftUI
import LumenUI
import EntitlementDiffCore
import EntitlementDiffModel

struct InputDetailsView: View {
    let state: InputState
    let sourceURL: URL?
    let disabled: Bool
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.regular) {
            AppDialogTitle(title: "Input Details")
            Divider()
            BoundedMetadataLayout(maximumHeight: 360) {
                metadata.fixedSize(horizontal: false, vertical: true).hidden()
                ScrollView { metadata.fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            Button("Reveal in Finder", action: reveal).disabled(sourceURL == nil || disabled || state.isLoading)
            Text("Bundle metadata is unverified display information. Location is session-only; reports omit it. Optional fields are limited to 256 UTF-8 bytes. Long locations and identifiers are previewed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppDesign.Space.section).frame(width: 440)
        .appDialogSurface()
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.regular) {
            field("Selected location", sourceURL?.path, limit: 4_096)
            if let snapshot = state.snapshot {
                if snapshot.isSavedBaseline {
                    Text("Saved report — unverified metadata. No selected app location or build metadata.")
                        .foregroundStyle(.secondary)
                } else if snapshot.origin == .syntheticExample {
                    Text("Synthetic example — no selected file or build metadata.").foregroundStyle(.secondary)
                } else {
                    field("Bundle identifier", snapshot.identity?.bundleIdentifier)
                    field("Version", snapshot.identity?.version)
                    field("Build number", snapshot.identity?.build)
                }
                field("Signing identifier", snapshot.signingIdentifier, limit: 4_096)
                Text("Requested architecture: \(snapshot.architecture.rawValue)")
            } else {
                Text(state.isLoading ? "Build metadata is being read…" : "Build metadata unavailable because inspection failed.")
                    .foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, _ value: String?, limit: Int = 256) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.small) {
            Text(title).font(.caption.weight(.semibold))
            LiteralMetadataText(value: value.map { EntitlementValue.string($0).preview(maxCharacters: limit) } ?? "Unavailable")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lumen's public code rows limit display lines. These bounded metadata previews must remain
/// fully selectable and scrollable without inserting typographic hyphens into paths or identifiers.
private struct LiteralMetadataText: NSViewRepresentable {
    let value: String
    @Environment(\.lumenPalette) private var palette

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineBreakStrategy = []
        paragraph.hyphenationFactor = 0
        paragraph.usesDefaultHyphenation = false
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
            .foregroundColor: NSColor(palette[.fgPrimary]), .paragraphStyle: paragraph
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size?.height ?? 0))
    }
}

/// Measure the intrinsic metadata before presenting the popover so short content does not
/// reserve the long-content viewport while long previews keep the footer on screen.
private struct BoundedMetadataLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
