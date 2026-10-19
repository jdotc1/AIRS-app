import SwiftUI
import LumenUI
import AIRSEntitlements
import EntitlementDiffCore

struct EntitlementBatchView: View {

    @Bindable var workspace: EntitlementsWorkspace
    @State private var confirmingHistoryDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppPageHeader(title: "Comparison Queue",
                subtitle: "Ordered Previous → Current pairs, one comparison at a time. The primary comparison stays unchanged until you review and open a result.") {
                Button("New Queue", action: workspace.clearBatch)
                    .disabled(workspace.isBusy || workspace.hasUnretainedBatchReport || workspace.batchNeedsHistorySave || workspace.batchNeedsCheckpointSave)
            }
            HStack {
                Button("Import Manifest…", action: workspace.chooseBatchManifest).disabled(!workspace.canImportBatchManifest)
                Menu("Export Manifest") {
                    Button("Absolute Paths…") { workspace.chooseBatchManifestExport() }
                    Button("Relative Paths…") { workspace.chooseBatchManifestExport(relativePaths: true) }
                }.fixedSize().disabled(!workspace.canExportBatchManifest)
                Text("Absolute or relative path plans. Import never starts a comparison.").font(.caption).foregroundStyle(.secondary)
            }
            if workspace.batchResult == nil {
                EntitlementBatchSelection(workspace: workspace)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let result = workspace.batchResult {
                        ForEach(result.rows) { row in
                            EntitlementBatchResultRow(row: row, busy: workspace.isBusy,
                                review: { workspace.reviewBatchReport(row.id) },
                                retry: { workspace.retryBatchRetention(row.id) },
                                export: { workspace.chooseBatchRecoveryExport(row.id) })
                        }
                    } else {
                        if workspace.batchPairs.isEmpty {
                            LumenEmptyState(systemImage: AppDesign.Symbol.batch, title: "No pairs in the queue",
                                message: "Choose two apps and Add Pair, or import a manifest to review its selections.")
                        }
                        ForEach(workspace.batchPairs) { pair in
                            HStack {
                                EntitlementBatchPairLabel(pair: pair)
                                Spacer()
                                Button("Remove Pair") { workspace.removeBatchPair(pair.id) }.disabled(!workspace.canEditBatch)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            // Queue and result rows share pair IDs but have different compositions.
            // Recreate the scroll content once per execution, not on every progress update.
            .id(workspace.batchResult?.id)
            if workspace.batchResult == nil {
                Button("Run and Keep Comparisons") { workspace.runBatch() }.disabled(!workspace.canRunBatch)
            } else if workspace.hasUnretainedBatchReport {
                LumenBanner("A complete report needs saving. Retry or export it before starting a new queue or quitting.", tone: .warning)
            }
            if let failure = workspace.batchCheckpoint?.persistenceError {
                LumenBanner("Recovery not saved: \(DisplayText.escaped(failure))", tone: .warning).textSelection(.enabled)
                Button("Retry Saving Recovery") { workspace.retryCheckpointSave() }.disabled(workspace.isBusy)
            }
            if workspace.batchCheckpoint != nil {
                HStack {
                    Button("Resume Remaining Pairs") { workspace.resumeBatch() }.disabled(!workspace.canResumeBatch)
                    Button("Leave for Recovery", action: workspace.leaveForRecovery).disabled(!workspace.canLeaveForRecovery)
                }
                let attempts = workspace.batchCheckpoint?.admissions.reduce(0) { $0 + $1.attempts.count } ?? 0
                if attempts > 0 { Text("\(attempts) earlier pair outcomes preserved in recovery.").font(.caption) }
            }
            if workspace.batchNeedsHistorySave && !workspace.hasUnretainedBatchReport {
                if let failure = workspace.batchHistoryFailure {
                    LumenBanner("History not saved: \(DisplayText.escaped(failure))", tone: .warning).textSelection(.enabled)
                }
                HStack {
                    Button("Retry Saving History") { workspace.retryBatchHistorySave() }.disabled(workspace.isBusy)
                    Button("Discard Unsaved History…") { confirmingHistoryDiscard = true }.disabled(workspace.isBusy)
                }
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Up to 16 pairs, 8 MiB per report, 128 MiB per batch. Main executable and requested architecture only. No signature validation or security verdict. Settled outcomes are saved after complete reports have a durable destination. Recovery checkpoints preserve queued work and complete pending reports. Resume checks the original apps and reader context; completed pairs are never rerun. Up to 16 resumptions per pair.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .confirmationDialog("Discard the unsaved batch history?", isPresented: $confirmingHistoryDiscard) {
            Button("Discard Unsaved History", role: .destructive, action: workspace.discardUnsavedBatchHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed reports remain saved. No immutable history entry will be saved now. A durable recovery checkpoint, if present, remains available separately.")
        }
    }
}

private struct EntitlementBatchSelection: View {
    @Bindable var workspace: EntitlementsWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose Previous App…") { workspace.chooseBatchInput(.previous) }
                Text(DisplayText.escaped(workspace.batchPrevious?.path ?? "No Previous app selected")).lineLimit(2).textSelection(.enabled)
            }
            HStack {
                Button("Choose Current App…") { workspace.chooseBatchInput(.current) }
                Text(DisplayText.escaped(workspace.batchCurrent?.path ?? "No Current app selected")).lineLimit(2).textSelection(.enabled)
            }
            HStack {
                Picker("Architecture for this pair", selection: Binding(
                    get: { workspace.batchArchitecture }, set: workspace.setBatchArchitecture)) {
                    ForEach(Architecture.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 310)
                Button("Add Pair", action: workspace.addSelectedBatchPair)
                    .disabled(workspace.batchPrevious == nil || workspace.batchCurrent == nil || workspace.batchPairs.count >= EntitlementBatchRunner.maximumPairs)
                Text("\(workspace.batchPairs.count) of 16 pairs").font(.caption)
            }
        }.disabled(!workspace.canEditBatch)
    }
}

struct EntitlementBatchPairLabel: View {
    let pair: EntitlementBatchPair
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(DisplayText.escaped(pair.previous.lastPathComponent)) → \(DisplayText.escaped(pair.current.lastPathComponent))").font(.headline)
            Text("\(pair.architecture.rawValue) · Previous: \(DisplayText.escaped(pair.previous.path))\nCurrent: \(DisplayText.escaped(pair.current.path))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct EntitlementBatchResultRow: View {
    let row: EntitlementBatchRow
    let busy: Bool
    let review: () -> Void
    let retry: () -> Void
    let export: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EntitlementBatchPairLabel(pair: row.pair)
            Text("\(row.status.title) · \(DisplayText.escaped(row.message))").textSelection(.enabled)
            if let changed = row.changedCount, let unchanged = row.unchangedCount {
                Text("\(changed) changed · \(unchanged) unchanged keys").font(.callout)
            }
            HStack {
                if row.retainedReportID != nil || row.exportedReportURL != nil || row.unretainedData != nil {
                    Button("Review Comparison…", action: review).disabled(busy)
                }
                if row.unretainedData != nil {
                    Button("Retry Saving to Library", action: retry).disabled(busy)
                    Button("Export Completed Report…", action: export).disabled(busy)
                }
            }
            Divider()
        }
    }
}
