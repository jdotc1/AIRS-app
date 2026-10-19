import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct ReportLibraryView: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: "Report Library",
                subtitle: "Retained copies preserve original JSON, image identity, model, configuration, and evidence. Opening a copy does not analyze its binary.") {
                Button("Refresh", action: workspace.refreshLibrary).disabled(workspace.isBusy)
            }
            if let current = workspace.report {
                Text("Current: \(current.image.displayName) · \(current.image.architecture) · \(current.generator.analysisModelVersion)")
                Text("Slice SHA-256: \(current.image.sliceSHA256)")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Keep Current Report", action: workspace.keepCurrentReport).disabled(workspace.isBusy)
            }
            if workspace.libraryEntries.isEmpty {
                LumenEmptyState(systemImage: "books.vertical", title: "No retained reports", message: "Open an audit report, then choose Keep Current Report. Reports are kept only when you request it.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.libraryEntries) { entry in
                            ReportLibraryRow(entry: entry, isBusy: workspace.isBusy,
                                canCompare: workspace.report != nil,
                                open: { workspace.openRetainedReport(entry.id) },
                                compare: { workspace.compareRetainedReport(entry.id) },
                                remove: { workspace.removeRetainedReport(entry.id) })
                            Divider()
                        }
                    }
                }
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Up to 128 reports / 128 MiB. Remove moves only the retained copy to Trash. Comparisons use the local Python engine; opening retained reports does not require Python.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct ReportLibraryRow: View {
    let entry: ReportLibraryEntry
    let isBusy: Bool
    let canCompare: Bool
    let open: () -> Void
    let compare: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.image?.displayName ?? "Unavailable retained report").font(.headline)
            if let image = entry.image {
                Text("\(image.architecture) · subtype \(image.cpuSubtype) · \(entry.model ?? "Unknown model")")
                Text("Slice SHA-256: \(image.sliceSHA256)")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let uuid = image.uuid { Text("UUID: \(uuid)").font(.caption).textSelection(.enabled) }
            }
            if let summary = entry.summary {
                Text("\(summary.functionCount) functions · \(summary.agreementCount) agreement · \(summary.inconsistencyCount) inconsistency · \(summary.unresolvedCount) unresolved")
                    .font(.callout)
            }
            Text(entry.sourceLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let date = entry.savedAt { Text("Kept \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
            if let issue = entry.issue { LumenBanner(issue, tone: .warning).textSelection(.enabled) }
            HStack {
                Button("Open Report", action: open).disabled(isBusy || entry.issue != nil)
                Button("Compare as Baseline", action: compare).disabled(isBusy || !canCompare || entry.issue != nil)
                Spacer()
                Button("Remove from Library", action: remove).disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
