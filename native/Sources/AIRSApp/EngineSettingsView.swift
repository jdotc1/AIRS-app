import SwiftUI
import LumenTokens
import LumenUI

@MainActor
struct EngineSettingsView: View {
    @ObservedObject var workspace: AuditWorkspace

    private var categories: [LumenSettingsCategory] {
        [
            LumenSettingsCategory(
                id: "engine", title: "Engine", systemImage: "cpu", hue: .hueViolet,
                keywords: ["Python", "runtime", "executable", "availability", "development"],
                settings: ["Use external Python", "Python executable", "Recheck Paths"]
            ) {
                EngineRuntimeSettingsPane(workspace: workspace)
            },
            LumenSettingsCategory(
                id: "reports", title: "Reports", systemImage: "doc.text", hue: .hueBlue,
                keywords: ["analysis", "library", "retained", "reuse", "import", "export"],
                settings: ["Reuse retained analyses"]
            ) {
                ReportSettingsPane(workspace: workspace)
            }
        ]
    }

    var body: some View {
        LumenSettingsSidebarView(categories)
    }
}

@MainActor
private struct EngineRuntimeSettingsPane: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        LumenSettingsPane("Engine", systemImage: "cpu", hue: .hueViolet,
                          summary: "The local runtime used to analyze your files.", style: .rich) {
            LumenFormSection("Local runtime") {
                LumenSettingsRow("Python runtime",
                                 description: workspace.setupMessage ?? workspace.engineRuntimeLabel) {
                    Button("Recheck Paths", action: workspace.refreshEngineAvailability)
                }
            }

            LumenFormSection("Development") {
                LumenSettingsRow("Use external Python",
                                 description: "Override the private runtime with your own interpreter.") {
                    Toggle("Use external Python", isOn: $workspace.usesExternalPython)
                        .toggleStyle(.switch)
                }
                VStack(alignment: .leading, spacing: AppDesign.Space.small) {
                    Text("Python executable").font(.callout).foregroundStyle(.secondary)
                    TextField("Python executable", text: $workspace.pythonPath,
                              prompt: Text("Private runtime by default"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!workspace.usesExternalPython)
                    HStack {
                        Button("Choose Executable…", action: workspace.choosePython)
                        Button("Use Private Runtime") { workspace.usesExternalPython = false }
                            .disabled(!workspace.usesExternalPython)
                    }
                }
                .padding(AppDesign.Space.medium)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                SettingsExplanation("The private runtime runs analysis in an isolated child process and never silently falls back to system Python. A saved path applies only with the override enabled.")
                DisclosureGroup("Source-only development builds") {
                    SettingsExplanation("Source-only builds can discover known absolute Python locations. Packaged AIRS includes private Python 3.15.0.")
                }
                .font(.caption)
            }
        }
    }
}

@MainActor
private struct ReportSettingsPane: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        LumenSettingsPane("Reports", systemImage: "doc.text", hue: .hueBlue,
                          summary: "Retained analyses and saved audit reports.", style: .rich) {
            LumenFormSection("Analysis reuse") {
                LumenSettingsRow("Reuse retained analyses",
                                 description: "Keep new owned audits in the report library and reuse matching analyses for unchanged inputs.") {
                    Toggle("Reuse retained analyses", isOn: $workspace.reusesRetainedAnalyses)
                        .toggleStyle(.switch)
                }
                SettingsExplanation("Applies to the same private engine. Imported reports and external Python are not eligible. Turn this off to request a new analysis. This choice lasts for this app session.")
            }
            LumenFormSection("Saved reports") {
                SettingsExplanation("Open and export existing audit JSON reports without the Python engine. A baseline comparison or handoff export requires the engine.")
                SettingsExplanation("Imports and generated reports are limited to 64 MiB.")
            }
        }
    }
}

private struct SettingsExplanation: View {
    let text: String
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenPalette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(metrics.typography.caption)
            .foregroundStyle(palette[.fgTertiary])
            .lumenWrapsWithoutTruncating()
    }
}
