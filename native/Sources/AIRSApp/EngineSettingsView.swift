import SwiftUI

@MainActor
struct EngineSettingsView: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPageHeader(title: "Engine Settings", subtitle: "Local runtime and retained audit reports") { EmptyView() }
                .padding(AppDesign.Space.page)
            Divider()
            Form {
                Section("Local Python engine") {
                    Text("Packaged AIRS includes private Python 3.15.0. Analysis uses the owned engine in an isolated child process.")
                        .foregroundStyle(.secondary)
                    Toggle("Use external Python (development)", isOn: $workspace.usesExternalPython)
                    TextField("Python executable", text: $workspace.pythonPath,
                              prompt: Text("Private runtime by default"))
                        .disabled(!workspace.usesExternalPython)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Choose Executable…", action: workspace.choosePython)
                        Button("Use Private Runtime") { workspace.usesExternalPython = false }
                            .disabled(!workspace.usesExternalPython)
                    }
                    Text("The private runtime is the default even when an older interpreter path is saved. Enable the development override to use that path. Source-only development builds can discover known absolute Python locations; packaged runtime failures do not silently use a system interpreter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Availability") {
                    if let message = workspace.setupMessage {
                        Label(message, systemImage: "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(workspace.engineRuntimeLabel, systemImage: "externaldrive")
                            .foregroundStyle(.secondary)
                    }
                    Button("Recheck Paths", action: workspace.refreshEngineAvailability)
                }
                Section("Reports") {
                    Toggle("Reuse retained analyses", isOn: $workspace.reusesRetainedAnalyses)
                    Text("When enabled, new owned audits are kept in the report library. Matching saved analyses can be reused for unchanged inputs and the same private engine. Imported reports and external Python are not eligible. Turn off to request a new analysis. This choice lasts for this app session.")
                        .foregroundStyle(.secondary)
                    Text("Existing audit JSON reports can be opened and exported independently of the Python engine. Imports and generated reports are limited to 64 MiB. A baseline comparison or handoff export uses the engine.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(AppDesign.Space.medium)
        }
        .frame(minWidth: 640, idealWidth: 640, minHeight: 680, idealHeight: 680)
        .appDialogSurface()
    }
}
