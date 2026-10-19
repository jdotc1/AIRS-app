import SwiftUI
import LumenUI
import EntitlementDiffCore

struct EntitlementLibraryView: View {
    @Bindable var workspace: EntitlementsWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppPageHeader(title: "Report Library",
                subtitle: "Keep both complete snapshots for later review. Reopening recomputes their differences without reading the source apps. Saved metadata remains unverified.") {
                Button("Refresh") { workspace.refreshLibrary() }.disabled(workspace.isBusy)
            }
            if let report = workspace.model.report {
                Text("Current: \(DisplayText.escaped(report.previous.sourceName)) → \(DisplayText.escaped(report.current.sourceName)) · \(report.previous.architecture.rawValue)")
                Button("Keep Current Entitlement Report") { workspace.keepCurrentReport() }.disabled(workspace.isBusy)
            }
            if workspace.libraryEntries.isEmpty {
                LumenEmptyState(systemImage: "books.vertical", title: workspace.libraryLoaded ? "No retained entitlement reports" : "Library not loaded", message: "Reports are kept only when you request it. Choose Keep Current Entitlement Report to retain the complete comparison.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(workspace.libraryEntries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                if let summary = entry.summary {
                                    Text("\(DisplayText.escaped(summary.previousName)) → \(DisplayText.escaped(summary.currentName))").font(.headline)
                                    Text("\(summary.architecture) · Previous: \(summary.previousKeys) keys · Current: \(summary.currentKeys) keys")
                                } else { Text("Unavailable retained report").font(.headline) }
                                if let date = entry.savedAt { Text("Kept \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                if let issue = entry.issue { LumenBanner(DisplayText.escaped(issue), tone: .warning).textSelection(.enabled) }
                                HStack {
                                    Button("Review Saved Snapshots…") { workspace.reviewRetainedReport(entry.id) }
                                        .disabled(workspace.isBusy || entry.issue != nil)
                                    Spacer()
                                    Button("Remove from Library") { workspace.removeRetainedReport(entry.id) }.disabled(workspace.isBusy)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
            DisclosureGroup("Storage and workflow details") {
                Text("Up to 128 reports / 128 MiB, 8 MiB per report. Remove moves only the retained copy to Trash. The audit report library is separate.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
