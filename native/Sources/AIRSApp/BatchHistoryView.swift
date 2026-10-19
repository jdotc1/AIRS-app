import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct BatchHistoryView: View {
    @ObservedObject var workspace: AuditWorkspace

    @State private var baseline: UUID?
    @State private var current: UUID?

    private var available: [BatchHistoryEntry] { workspace.batchHistoryEntries.filter { $0.issue == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: "Batch History",
                subtitle: "Open a saved checkpoint to inspect every selected image and explicitly resume remaining work. Completed reports are never automatically analyzed again.") {
                Button("Refresh", action: workspace.openBatchHistory).disabled(workspace.isBusy)
            }
            HStack {
                Picker("Baseline batch", selection: $baseline) {
                    Text("Choose baseline").tag(nil as UUID?)
                    ForEach(available) { entry in Text(batchLabel(entry)).tag(Optional(entry.id)) }
                }
                Picker("Current batch", selection: $current) {
                    Text("Choose current").tag(nil as UUID?)
                    ForEach(available) { entry in Text(batchLabel(entry)).tag(Optional(entry.id)) }
                }
                Button("Review Pairing…") {
                    if let baseline, let current { workspace.prepareBatchComparison(baseline: baseline, current: current) }
                }.disabled(workspace.isBusy || baseline == nil || current == nil || baseline == current
                    || !available.contains { $0.id == baseline } || !available.contains { $0.id == current })
            }
            if workspace.batchHistoryEntries.isEmpty {
                LumenEmptyState(systemImage: "clock.arrow.circlepath", title: "No saved batches", message: "Analyze Selected Images creates a checkpoint before launching work.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.batchHistoryEntries) { entry in
                            BatchHistoryRow(entry: entry, isBusy: workspace.isBusy,
                                open: { workspace.loadBatchHistory(entry.id) },
                                remove: { workspace.removeBatchHistory(entry.id) })
                            Divider()
                        }
                    }
                }
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Up to 64 batch checkpoints and 128 MiB of pending recovery reports. Remove moves history and its recovery copy to Trash; reports already in Report Library remain.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onChange(of: available.map(\.id)) { _, ids in
            if let baseline, !ids.contains(baseline) { self.baseline = nil }
            if let current, !ids.contains(current) { self.current = nil }
        }
    }
    private func batchLabel(_ entry: BatchHistoryEntry) -> String {
        "\(entry.updatedAt?.formatted() ?? "Unavailable") · \(entry.id.uuidString.prefix(8)) · \(entry.snapshot?.items.count ?? 0) images"
    }
}

private struct BatchHistoryRow: View {
    let entry: BatchHistoryEntry
    let isBusy: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.updatedAt?.formatted() ?? "Unavailable checkpoint").font(.headline)
            Text(entry.id.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let snapshot = entry.snapshot {
                Text("\(snapshot.items.count) selected · \(snapshot.items.filter { $0.status == .completed }.count) completed · \(snapshot.items.filter { $0.status == .failed }.count) failed · \(snapshot.items.filter { [.queued, .running, .cancelled, .notStarted].contains($0.status) }.count) unfinished")
                Text(snapshot.items.map { $0.input.lastPathComponent }.joined(separator: ", "))
                    .font(.caption).lineLimit(3)
            }
            if let issue = entry.issue { LumenBanner(issue, tone: .warning).textSelection(.enabled) }
            HStack {
                Button("Open Checkpoint", action: open).disabled(isBusy || entry.issue != nil)
                Spacer()
                Button("Remove History…") { confirmingRemoval = true }.disabled(isBusy)
            }
        }
        .confirmationDialog("Move this batch history and any pending recovery report to Trash?", isPresented: $confirmingRemoval) {
            Button("Move History to Trash", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reports already retained in Report Library and original inputs remain unchanged.")
        }
    }
}
