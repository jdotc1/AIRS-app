import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct BatchComparisonView: View {
    let plan: BatchComparisonPlan
    @ObservedObject var workspace: AuditWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [UUID: UUID]
    @State private var detail: ComparisonDocument?

    init(plan: BatchComparisonPlan, workspace: AuditWorkspace) {
        self.plan = plan; self.workspace = workspace
        _choices = State(initialValue: Dictionary(uniqueKeysWithValues: plan.suggestions.map { ($0.currentID, $0.baselineID) }))
    }
    private var pairs: [BatchImagePair] {
        plan.current.items.compactMap { item in choices[item.id].map { BatchImagePair(baselineID: $0, currentID: item.id) } }
    }
    private var valid: Bool { (try? plan.validate(pairs)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppDialogTitle(title: "Saved-batch baseline comparison")
                Spacer()
                if workspace.isBusy { Button("Cancel", action: workspace.cancel).disabled(!workspace.canCancel) }
                Button("Done") { dismiss() }.disabled(workspace.isBusy)
            }
            Text("Baseline \(plan.baseline.id.uuidString) → Current \(plan.current.id.uuidString)")
                .font(.caption).textSelection(.enabled)
            if let result = workspace.batchComparisonResult, result.plan.id == plan.id {
                results(result)
            } else {
                pairing
            }
        }
        .padding(AppDesign.Space.page).frame(minWidth: 800, idealWidth: 980, minHeight: 620, idealHeight: 750)
        .appDialogSurface()
        .interactiveDismissDisabled(workspace.isBusy)
        .sheet(item: $detail) { document in ComparisonView(document: document, workspace: workspace) }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a baseline for each current image. Unique exact-slice matches are suggestions; Confirm Pairing submits your choices. Different builds require an explicit selection. Names and row order do not prove identity.")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(plan.current.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            imageLabel(item)
                            Picker("Baseline image", selection: Binding<UUID?>(get: { choices[item.id] }, set: { choices[item.id] = $0 })) {
                                Text("Unpaired — keep visible").tag(nil as UUID?)
                                ForEach(plan.baseline.items) { old in
                                    Text("\(old.input.lastPathComponent) · \(old.status.title) · \(old.id.uuidString.prefix(8))").tag(Optional(old.id))
                                }
                            }.disabled(workspace.isBusy)
                            if let selected = choices[item.id], let old = plan.baseline.items.first(where: { $0.id == selected }) {
                                imageLabel(old)
                            }
                            Divider()
                        }
                    }
                    Text("Baseline inventory (unpaired rows remain in the result)").font(.headline)
                    ForEach(plan.baseline.items) { item in imageLabel(item) }
                }
            }
            if !valid { LumenBanner("A baseline image is selected more than once. Each image may be paired only once.", tone: .warning) }
            Button("Confirm Pairing and Compare") { workspace.compareSavedBatches(pairs) }
                .disabled(workspace.isBusy || !valid)
        }
    }

    private func imageLabel(_ item: ImageBatchItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(item.input.lastPathComponent) · \(item.status.title)").font(.headline)
            Text(item.input.path).font(.caption).textSelection(.enabled)
            Text(item.message).font(.caption).foregroundStyle(.secondary)
            if let image = item.image {
                Text("\(image.architecture) / subtype \(image.cpuSubtype) · \(item.model ?? "Unknown model")\nSlice SHA-256: \(image.sliceSHA256)\nUUID: \(image.uuid ?? "Absent")")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func results(_ result: BatchComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(plan.baseline.items.count) baseline images · \(plan.current.items.count) current images · \(result.rows.filter { $0.state == "compared" }.count) compared pairs\(result.cancelled ? " · Cancelled" : "")")
            Text("Unpaired and unavailable images remain visible. Changed findings are not automatically regressions; added/removed unmatched functions are not fixes.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(result.rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(row.baseline?.input.lastPathComponent ?? "No baseline") → \(row.current?.input.lastPathComponent ?? "No current")").font(.headline)
                            Text("\(row.state) · \(row.message)").textSelection(.enabled)
                            Text("Baseline: \(row.baseline?.status.title ?? "Unpaired") · Current: \(row.current?.status.title ?? "Unpaired")").font(.caption)
                            if let comparison = row.comparison, let data = row.comparisonData {
                                Text("\(comparison.summary.changedCount) changed · \(comparison.summary.unchangedCount) unchanged · \(comparison.summary.ambiguousCount) ambiguous functions")
                                Button("Inspect Function Comparison…") {
                                    detail = ComparisonDocument(report: comparison, data: data, formattedJSON: String(decoding: data, as: UTF8.self),
                                        protectedInputs: (plan.baseline.items + plan.current.items).flatMap { [$0.input] + [$0.bundleImage?.bundle].compactMap { $0 } })
                                }.disabled(workspace.isBusy)
                            }
                            Divider()
                        }
                    }
                }
            }
            Button("Export Batch Comparison JSON…", action: workspace.exportBatchComparison)
                .disabled(workspace.isBusy || !result.settled)
        }
    }
}
