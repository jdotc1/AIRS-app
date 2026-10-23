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
    @State private var changePage = 0

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
                        // Six fixed tiles can be measured eagerly while the native
                        // sheet negotiates its initial size through the ScrollView.
                        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow {
                                StatTile(value: document.report.summary.matchedCount, title: "Matched functions")
                                StatTile(value: document.report.summary.changedCount, title: "Changed findings", tint: .orange)
                                StatTile(value: document.report.summary.unchangedCount, title: "Unchanged findings")
                            }
                            GridRow {
                                StatTile(value: document.report.summary.addedCount, title: "Added functions")
                                StatTile(value: document.report.summary.removedCount, title: "Removed functions")
                                StatTile(value: document.report.summary.ambiguousCount, title: "Ambiguous comparisons")
                            }
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
                            .onChange(of: showUnchanged) { _, _ in changePage = 0 }
                        if visibleChanges.isEmpty {
                            LumenEmptyState("No changes are visible with this filter.", prominence: .inline)
                        } else {
                            let page = ComparisonChangePage(count: visibleChanges.count, index: changePage)
                            if page.pageCount > 1 {
                                HStack {
                                    Text("Findings \(page.range.lowerBound + 1)–\(page.range.upperBound) of \(visibleChanges.count)")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Previous") { changePage = page.index - 1 }
                                        .disabled(page.index == 0)
                                    Button("Next") { changePage = page.index + 1 }
                                        .disabled(page.index + 1 == page.pageCount)
                                }
                            }
                            // Eager, bounded rows avoid lazy scroll preferences feeding
                            // back into native sheet sizing, even after filter changes.
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(visibleChanges[page.range].enumerated()), id: \.offset) { index, change in
                                    if index > 0 { Divider() }
                                    ComparisonChangeView(change: change)
                                }
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

/// Bounds eager view construction without truncating or changing report evidence.
struct ComparisonChangePage {
    static let size = 50
    let index: Int
    let pageCount: Int
    let range: Range<Int>

    init(count: Int, index: Int) {
        let count = max(0, count)
        pageCount = count / Self.size + (count % Self.size == 0 ? 0 : 1)
        self.index = min(max(0, index), max(0, pageCount - 1))
        let lower = self.index * Self.size
        range = lower..<(lower + min(Self.size, count - lower))
    }
}
