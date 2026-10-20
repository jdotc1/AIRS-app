import SwiftUI
import LumenUI
import AIRSEntitlements
import EntitlementDiffCore

struct EntitlementBatchHistoryView: View {
    @Bindable var workspace: EntitlementsWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: "Batch History",
                subtitle: "Saved outcomes preserve pair order and requested architecture. Opening history never reads the apps or resumes work.") {
                if workspace.selectedBatchHistory != nil {
                    Button("All History", action: workspace.backToBatchHistory).disabled(workspace.isBusy)
                } else {
                    Button("Refresh") { workspace.refreshBatchHistory() }.disabled(workspace.isBusy)
                }
            }
            if let record = workspace.selectedBatchHistory {
                Text("Settled \(record.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.result.rows.count) pairs")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(record.result.rows) { row in
                            EntitlementBatchResultRow(row: row, busy: workspace.isBusy,
                                review: { workspace.reviewHistoryReport(row.id) }, retry: {}, export: {})
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(record.result.id)
            } else if workspace.batchHistoryEntries.isEmpty {
                LumenEmptyState(systemImage: "clock.arrow.circlepath", title: workspace.batchHistoryLoaded ? "No saved entitlement batches" : "History not loaded", message: "Run and Keep Comparisons saves settled outcomes after completed reports have been retained or exported.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.batchHistoryEntries) { entry in
                            EntitlementBatchHistoryRow(entry: entry, busy: workspace.isBusy,
                                open: { workspace.loadBatchHistory(entry.id) },
                                remove: { workspace.removeBatchHistory(entry.id) })
                            if let ids=workspace.projectHistoryIDs[entry.id],!ids.isEmpty {Text("Project IDs: "+ids.map(\.uuidString).joined(separator:", ")).textSelection(.enabled).foregroundStyle(.secondary)}
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Up to 64 history records / 32 MiB; 512 KiB per record. History includes local app paths. Remove moves only the history record to Trash; completed reports remain separate. A missing or changed report remains unavailable. Use Recovery for queued work and pending complete reports; History contains immutable settled outcomes.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

private struct EntitlementBatchHistoryRow: View {
    let entry: EntitlementBatchHistoryEntry
    let busy: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = entry.summary {
                Text(summary.finishedAt, format: .dateTime.year().month().day().hour().minute()).font(.headline)
                Text("\(summary.pairs) pairs · \(summary.completed) completed · \(summary.failed) failed\(summary.cancelled ? " · cancelled" : "")")
                Text(summary.batchID.uuidString).font(.caption).textSelection(.enabled)
            } else { Text("Unavailable history record").font(.headline) }
            if let issue = entry.issue { LumenBanner(DisplayText.escaped(issue), tone: .warning).textSelection(.enabled) }
            HStack {
                Button("Open Outcomes", action: open).disabled(busy || entry.issue != nil)
                Spacer()
                Button("Remove History…") { confirmingRemoval = true }.disabled(busy)
            }
            Divider()
        }
        .confirmationDialog("Move this history record to Trash?", isPresented: $confirmingRemoval) {
            Button("Move History to Trash", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Completed reports, source apps and the current batch remain unchanged.") }
    }
}
