import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct ComparisonView: View {
    let document: ComparisonDocument
    @ObservedObject var workspace: AuditWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var showUnchanged = false
    @State private var showJSON = false

    private var visibleChanges: [ComparisonChange] {
        document.report.changes.filter { showUnchanged || $0.change != "unchanged" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    AppDialogTitle(title: "Baseline comparison")
                    Text("\(document.report.comparison.baselineImage.displayName) → \(document.report.comparison.currentImage.displayName)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export JSON…") { workspace.exportComparison(document) }
                    .disabled(workspace.isBusy)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(AppDesign.Space.page)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionCard("Comparison scope") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            StatTile(value: document.report.summary.matchedCount, title: "Matched functions")
                            StatTile(value: document.report.summary.changedCount, title: "Changed findings", tint: .orange)
                            StatTile(value: document.report.summary.unchangedCount, title: "Unchanged findings")
                            StatTile(value: document.report.summary.addedCount, title: "Added functions")
                            StatTile(value: document.report.summary.removedCount, title: "Removed functions")
                            StatTile(value: document.report.summary.ambiguousCount, title: "Ambiguous comparisons")
                        }
                        FactRow(label: "Image identity", value: document.report.comparison.sameImage
                                ? "Same selected image" : "Different selected images")
                        FactRow(label: "Analysis models", value: document.report.comparison.modelCompatible
                                ? "Compatible model versions" : "Model versions differ; interpret comparisons with the reported limitations")
                        FactRow(label: "Matching policy", value: document.report.comparison.matchingPolicy, monospaced: true)
                    }
                    LimitationsView(title: "Comparison limitations", limitations: document.report.limitations)
                    SectionCard("Function changes") {
                        Toggle("Include unchanged findings", isOn: $showUnchanged)
                        if visibleChanges.isEmpty {
                            LumenEmptyState("No changes are visible with this filter.", prominence: .inline)
                        }
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(visibleChanges.enumerated()), id: \.offset) { index, change in
                                if index > 0 { Divider() }
                                ComparisonChangeView(change: change)
                            }
                        }
                    }
                    DisclosureGroup("Complete comparison JSON", isExpanded: $showJSON) {
                        ScrollView(.horizontal) {
                            Text(document.formattedJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(AppDesign.Space.page)
            }
        }
        .frame(minWidth: 780, idealWidth: 940, minHeight: 600, idealHeight: 740)
        .appDialogSurface()
    }
}

struct ComparisonChangeView: View {
    let change: ComparisonChange

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(change.functionName)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Spacer()
                Text(readableToken(change.change)).font(.caption.weight(.semibold))
                    .foregroundStyle(change.change == "changed" ? Color.orange : Color.secondary)
            }
            FactRow(label: "Match basis", value: readableToken(change.matchBasis))
            HStack(alignment: .top, spacing: 12) {
                EvidenceValueView(title: "Baseline", value: stateText(verdict: change.beforeVerdict, scope: change.beforeScope))
                EvidenceValueView(title: "Current", value: stateText(verdict: change.afterVerdict, scope: change.afterScope))
            }
            ForEach(Array(change.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func stateText(verdict: AuditVerdict?, scope: String?) -> String {
        var parts = [verdict?.title ?? "No matched finding"]
        if let scope { parts.append("Scope: \(readableToken(scope))") }
        return parts.joined(separator: "\n")
    }
}
