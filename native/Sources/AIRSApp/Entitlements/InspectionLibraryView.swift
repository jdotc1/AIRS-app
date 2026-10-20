import SwiftUI

struct InspectionLibraryView: View {
    @Bindable var workspace: EntitlementsWorkspace
    @State private var query = ""
    @State private var removalID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Inspection Baselines").font(.title2.bold())
                Spacer()
                Button("Done", action: workspace.closeInspectionLibrary)
            }
            TextField("Search baseline names or apps", text: $query).textFieldStyle(.roundedBorder)
            if workspace.inspectionEntries.isEmpty {
                Text("No retained baselines. Inspect an app, then choose Capture Baseline.").foregroundStyle(.secondary)
            }
            List(workspace.inspectionEntries.filter {
                $0.summary?.matches(query, label: $0.sourceLabel) ?? (query.isEmpty || $0.sourceLabel.localizedStandardContains(query))
            }) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.sourceLabel + (workspace.pinnedInspectionID == entry.id ? " · Default" : "")).font(.headline)
                        if let summary = entry.summary {
                            Text("\(summary.sourceName) · \(summary.architecture) · \(summary.capturedAt.formatted())")
                        }
                        if let issue = entry.issue { Text(issue).foregroundStyle(.red) }
                    }
                    Spacer()
                    Button(workspace.pinnedInspectionID == entry.id ? "Unpin" : "Pin as Default") {
                        workspace.pinInspection(workspace.pinnedInspectionID == entry.id ? nil : entry.id)
                    }.disabled(entry.issue != nil)
                    Button("Review") { workspace.reviewInspection(entry.id) }.disabled(entry.issue != nil)
                    Button("Remove…") { removalID = entry.id }
                }
            }
            Text("Retained documents contain declarations and recorded labels, never original app binaries.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).disabled(workspace.isWorking)
        .confirmationDialog("Remove this retained baseline?", isPresented: Binding(
            get: { removalID != nil }, set: { if !$0 { removalID = nil } })) {
            Button("Remove Baseline", role: .destructive) {
                if let id = removalID { workspace.removeInspection(id) }
                removalID = nil
            }
        } message: { Text("The original app and active snapshots remain available. The retained library copy will be deleted.") }
    }
}
