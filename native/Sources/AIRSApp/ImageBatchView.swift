import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct ImageBatchView: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Image Batches").font(AppDesign.Layout.pageTitle)
                Spacer()
                if workspace.isBusy && workspace.canCancel {
                    Button("Cancel Batch", action: workspace.cancel)
                }
                Button("Resume Remaining", action: workspace.resumeBatch).disabled(!workspace.canResumeBatch)
                if workspace.hasUnsavedBatchHistory {
                    Button("Save Checkpoint", action: workspace.saveBatchHistory).disabled(workspace.isBusy)
                }
                Button("Done") { workspace.showingBatch = false }
            }
            Text("Up to 16 explicitly selected images · one owned analysis at a time · only explicitly selected images")
                .foregroundStyle(.secondary)
            if let snapshot = workspace.batchSnapshot {
                ImageBatchSummary(snapshot: snapshot, isActive: workspace.isBusy)
                if let error = snapshot.persistenceError {
                    LumenBanner(error, tone: .warning).textSelection(.enabled)
                }
                if !workspace.isBusy && snapshot.items.contains(where: { $0.status == .running }) {
                    LumenBanner("This checkpoint was interrupted before child settlement was recorded. Resume is unavailable because prior child ownership is uncertain; no automatic replay is performed.", tone: .warning)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.items) { item in
                            ImageBatchRow(item: item, isBusy: workspace.isBusy,
                                open: { workspace.openBatchReport(item) },
                                retry: { workspace.retryBatchRetention(item) },
                                discard: { workspace.discardBatchSessionCopy(item.id) })
                            Divider()
                        }
                    }
                }
            } else {
                LumenEmptyState(systemImage: AppDesign.Symbol.batch, title: "No image batch",
                    message: "Select up to 16 images, or open a checkpoint from Batch History.",
                    actionTitle: "Select Images…", action: workspace.chooseBatch)
                    .disabled(workspace.isBusy || workspace.hasUnretainedBatchReports)
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Batch inventory and recovery copies persist in Batch History. Resume explicitly retries only queued, cancelled and not-started images with unchanged input and engine metadata. Completed and failed outcomes remain; completed reports keep their original bytes and identity.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct ImageBatchSummary: View {
    let snapshot: ImageBatchSnapshot
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(snapshot.items.count) selected images · \(snapshot.settled ? "Stopped" : (isActive ? "In progress" : "Unfinished checkpoint"))")
                .font(.headline)
            Text("\(count(.completed)) completed · \(count(.failed)) failed · \(count(.cancelled)) cancelled · \(count(.notStarted)) not started · \(count(.duplicate)) duplicate selections · \(count(.queued) + count(.running)) pending")
                .font(.callout)
            if snapshot.hasUnretainedReports {
                LumenBanner("A completed report awaits library retention. A saved checkpoint preserves its recovery bytes across quit. Retry Keep, or open/export it before explicitly discarding its recovery copy.", tone: .warning)
            }
        }
    }

    private func count(_ status: ImageBatchStatus) -> Int { snapshot.items.filter { $0.status == status }.count }
}

private struct ImageBatchRow: View {
    let item: ImageBatchItem
    let isBusy: Bool
    let open: () -> Void
    let retry: () -> Void
    let discard: () -> Void
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.input.lastPathComponent).font(.headline)
            if let provenance = item.bundleImage {
                Text("Bundle: \(provenance.bundle.path)\nImage: \(provenance.relativePath)\nDiscovery: \(provenance.inventoryID.uuidString)\(provenance.inventoryPartial ? " · Partial inventory" : "")").font(.caption).textSelection(.enabled)
            }
            Text(item.input.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(item.reusedAt != nil ? "Reused saved analysis" : (item.status == .running && !isBusy ? "Interrupted before settlement" : item.status.title)).font(.callout.weight(.semibold))
            Text(item.message).font(.callout).textSelection(.enabled)
            if !item.attempts.isEmpty {
                DisclosureGroup("Previous outcomes (\(item.attempts.count))") {
                    Text(item.attempts.map { "\($0.date.formatted()): \($0.status.title) — \($0.message)" }.joined(separator: "\n"))
                        .font(.caption).textSelection(.enabled)
                }
            }
            if let image = item.image {
                Text("\(image.architecture) · subtype \(image.cpuSubtype) · \(item.model ?? "Unknown model")")
                    .font(.caption)
                Text("Slice SHA-256: \(image.sliceSHA256)")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let uuid = image.uuid { Text("UUID: \(uuid)").font(.caption).textSelection(.enabled) }
            }
            if let summary = item.summary {
                Text("\(summary.functionCount) functions · \(summary.agreementCount) agreement · \(summary.inconsistencyCount) inconsistency · \(summary.unresolvedCount) unresolved · \(summary.checkedPCCount) modeled PC observations")
                    .font(.caption)
            }
            HStack {
                if item.retainedReportID != nil || item.unretainedData != nil {
                    Button("Open Report", action: open).disabled(isBusy)
                }
                if item.unretainedData != nil {
                    Button("Retry Keep", action: retry).disabled(isBusy)
                    Button("Discard Session Copy…") { confirmingDiscard = true }.disabled(isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Discard this completed report's unsaved session copy?", isPresented: $confirmingDiscard) {
            Button("Discard Session Copy", role: .destructive, action: discard)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The library has no retained copy. Open and export the report first if you need to preserve it. Original input files are unaffected.")
        }
    }
}
