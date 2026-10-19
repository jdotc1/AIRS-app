import SwiftUI
import EntitlementDiffCore
import EntitlementDiffModel

struct ChangeTable: View {
    let rows: [EntitlementChange]
    @Binding var selection: String?

    @Binding var sortOrder: [BrowserSort]

    let revealID: String?
    let revealRevision: UUID

    var body: some View {
        ScrollViewReader { proxy in
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Change", sortUsing: BrowserSort(column: .change)) { row in
                Label(row.kind.label, systemImage: symbol(row.kind))
                    .font(.caption)
                    .foregroundStyle(row.kind == .unchanged ? .secondary : .primary)
            }.width(min: 80, ideal: 90, max: 110)
            TableColumn("Entitlement", sortUsing: BrowserSort(column: .key)) { row in
                Text(EntitlementValue.string(row.key).preview(maxCharacters: 512))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .help(EntitlementValue.string(row.key).preview(maxCharacters: 512))
            }.width(min: 180, ideal: 240)
            TableColumn("Previous") { row in
                Text(row.previous?.preview() ?? "<absent>")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }.width(min: 100, ideal: 140)
            TableColumn("Current") { row in
                Text(row.current?.preview() ?? "<absent>")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }.width(min: 100, ideal: 140)
        }
        .accessibilityLabel("Entitlement comparison. Select a row to inspect its values.")
        .onChange(of: revealRevision) { _, _ in
            if let revealID { proxy.scrollTo(revealID, anchor: .center) }
        }
        }
    }

    private func symbol(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .removed: "minus.circle"
        case .changed: "arrow.left.arrow.right.circle"
        case .unchanged: "equal.circle"
        }
    }
}
