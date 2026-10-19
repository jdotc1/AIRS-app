import SwiftUI
import AIRSCore

@MainActor
struct BundleDiscoveryView: View {
    let inventory: BundleDiscoveryResult
    @ObservedObject var workspace: AuditWorkspace
    @State private var selected = Set<UUID>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppDialogTitle(title: "Review App Images")
                Spacer()
                Button("Done") { dismiss() }.disabled(workspace.isBusy)
            }
            Text(inventory.bundle.path).font(.caption).textSelection(.enabled)
            Text("\(inventory.partial ? "Partial inventory" : "Code-location inventory")\(inventory.cancelled ? " · Discovery cancelled" : "") · \(inventory.visited) visited entries · \(inventory.headerBytes) header bytes")
                .foregroundStyle(inventory.partial ? .orange : .secondary)
            Text("Choose up to 16 candidates. Header hints are not validated reports. Selected images are read as data by the existing engine; no inspected code executes. Analysis errors remain individual outcomes.")
            Text("Scope: Contents/MacOS, Frameworks, PlugIns, XPCServices, Helpers and Library/LoginItems. Links are skipped. Top-level Contents/Resources and other locations are outside this inventory. Limits: 4,096 entries, depth 12, 128 candidates, 1 MiB header reads.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(inventory.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            if entry.selectable {
                                Toggle(entry.relativePath, isOn: Binding(get: { selected.contains(entry.id) }, set: { value in
                                    if value { selected.insert(entry.id) } else { selected.remove(entry.id) }
                                })).disabled(workspace.isBusy)
                            } else { Text(entry.relativePath).font(.headline) }
                            Text("\(entry.state) · \(entry.message)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Text("\(selected.count) selected · no automatic selection")
                Spacer()
                Button("Analyze Selected Images") { workspace.analyzeDiscoveredImages(selected) }
                    .disabled(workspace.isBusy || selected.isEmpty || selected.count > 16 || workspace.hasUnretainedBatchReports)
            }
        }
        .padding(AppDesign.Space.page).frame(minWidth: 820, idealWidth: 980, minHeight: 620, idealHeight: 760)
        .appDialogSurface()
        .interactiveDismissDisabled(workspace.isBusy)
    }
}
