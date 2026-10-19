import SwiftUI
import LumenUI
import AIRSEntitlements
import EntitlementDiffCore

struct EntitlementBatchRecoveryView: View {
    @Bindable var workspace: EntitlementsWorkspace
    @State private var removing: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppPageHeader(title: "Recovery",
                subtitle: "Opening recovery never reads an app. Save completed reports before explicitly resuming remaining pairs. Clear the current queue or leave it for recovery before opening another batch.") {
                Button("Refresh") { workspace.openBatchRecovery() }.disabled(workspace.isBusy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(workspace.recoveryEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.updatedAt?.formatted() ?? "Incomplete checkpoint").font(.headline)
                            if let checkpoint = entry.snapshot {
                                Text("\(checkpoint.result.rows.count) pairs · \(checkpoint.result.rows.filter { $0.status == .completed }.count) completed · \(checkpoint.result.settled ? "settled" : "interrupted or owned by another process")")
                                Text(checkpoint.result.rows.first.map { "\(DisplayText.escaped($0.pair.previous.lastPathComponent)) → \(DisplayText.escaped($0.pair.current.lastPathComponent))" } ?? "")
                                Button("Open Recovery") { workspace.recoverBatch(entry.id) }
                                    .disabled(workspace.isBusy || workspace.batchResult != nil || !workspace.batchPairs.isEmpty)
                            }
                            if let issue = entry.issue { LumenBanner(DisplayText.escaped(issue), tone: .warning).textSelection(.enabled) }
                            Button("Remove Recovery…", role: .destructive) { removing = entry.id }
                                .disabled(workspace.isBusy || workspace.batchCheckpoint?.id == entry.id)
                            Divider()
                        }
                    }
                    if workspace.recoveryEntries.isEmpty { LumenEmptyState("No recovery checkpoints.", prominence: .inline) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Storage and workflow details") {
                Text("64 checkpoints and 128 MiB of pending reports. Checkpoints store local paths. Existing settled history and retained reports remain separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .confirmationDialog("Remove this recovery checkpoint?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move Recovery to Trash", role: .destructive) {
                if let id = removing { workspace.removeBatchRecovery(id) }; removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This removes its queue and any pending complete report from Recovery. Retained reports and settled history remain unchanged.")
        }
    }
}
