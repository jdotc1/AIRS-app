import SwiftUI
import LumenUI
import AIRSCore

@MainActor
struct WorkspaceView: View {
    @Environment(\.lumenPalette) private var palette

    @ObservedObject var workspace: AuditWorkspace
    @State private var listSelection: WorkspaceSelection?

    init(workspace: AuditWorkspace) {
        self.workspace = workspace
        _listSelection = State(initialValue: workspace.selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.showingBatchHistory {
                BatchHistoryView(workspace: workspace)
            } else if workspace.showingBatch {
                ImageBatchView(workspace: workspace)
            } else if workspace.showingLibrary {
                ReportLibraryView(workspace: workspace)
            } else if let report = workspace.report {
                HSplitView {
                    sidebar.frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
                    VStack(spacing: 0) {
                        if workspace.selectedFindingIsHidden {
                            HiddenFindingNotice(reveal: workspace.revealSelectedFinding,
                                overview: { workspace.selection = .overview })
                                .disabled(workspace.isBusy)
                            Divider()
                        }
                        if let finding = workspace.selectedFinding {
                            FindingDetailView(report: report, finding: finding,
                                              isBusy: workspace.isBusy) {
                                workspace.exportHandoff(finding)
                            }
                        } else {
                            ReportOverviewView(report: report, sourceLabel: workspace.sourceLabel)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                WelcomeView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("AIRS", isPresented: $workspace.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.errorMessage)
        }
        .onChange(of: workspace.selection) { _, _ in
            if listSelection != workspace.selection { listSelection = workspace.selection }
            workspace.showingLibrary = false
            workspace.showingBatch = false
            workspace.showingBatchHistory = false
        }
        .onChange(of: listSelection) { _, selection in
            if workspace.selection != selection { workspace.selection = selection }
        }
        .sheet(item: $workspace.bundleDiscovery) { inventory in
            BundleDiscoveryView(inventory: inventory, workspace: workspace)
        }
        .sheet(item: $workspace.batchComparisonPlan) { plan in
            BatchComparisonView(plan: plan, workspace: workspace)
        }
        .sheet(item: $workspace.comparisonDocument) { document in
            ComparisonView(document: document, workspace: workspace)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let report = workspace.report {
                VStack(alignment: .leading, spacing: 7) {
                    Text(report.image.displayName)
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text("\(report.image.architecture) · \(report.summary.functionCount) functions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Find a function or address", text: $workspace.search)
                        .textFieldStyle(.roundedBorder)
                    Picker("Verdict", selection: $workspace.verdictFilter) {
                        ForEach(VerdictFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Filter verdicts")
                }
                .padding(14)
                Divider()
                // Native List owns its transient selection update. Publish the shared
                // selection from onChange, outside its AppKit update callback.
                List(selection: $listSelection) {
                    Section {
                        Label("Report overview", systemImage: "chart.bar.doc.horizontal")
                            .tag(WorkspaceSelection.overview)
                    }
                    Section("Functions · \(workspace.visibleFindings.count) shown") {
                        if workspace.visibleFindings.isEmpty {
                            VStack(alignment: .leading, spacing: AppDesign.Space.small) {
                                Text("No matching functions").font(.headline)
                                Text("Change the search or verdict filter. Report overview remains available above.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical, AppDesign.Space.small)
                        }
                        ForEach(workspace.visibleFindings) { finding in
                            FindingRow(finding: finding)
                                .tag(WorkspaceSelection.finding(finding.id))
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("AIRS", systemImage: "waveform.path")
                        .font(.title2.weight(.semibold))
                    Text("Inspect compact-unwind metadata and bounded ARM64 evidence.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Developer starter · report schema 1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .background(palette[.bgSidebar])
    }
}

private struct HiddenFindingNotice: View {
    let reveal: () -> Void
    let overview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.small) {
            Text("Selected function is hidden by the current filters.").font(.callout.weight(.semibold))
            Text("Its evidence remains displayed below.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: AppDesign.Space.medium) {
                Button("Show Selected Function", action: reveal)
                Button("Report Overview", action: overview)
            }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppDesign.Space.medium)
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: finding.verdict.systemImage)
                .foregroundStyle(finding.verdict.tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(finding.displayName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2)
                Text(finding.verdict.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(finding.function.address)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

@MainActor
struct WelcomeView: View {
    @ObservedObject var workspace: AuditWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AppPageHeader(title: "Unwind Analysis",
                    subtitle: "Inspect compact-unwind metadata and bounded ARM64 evidence.") {
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: AppDesign.Space.medium) {
                    LumenEmptyState(systemImage: "waveform.path", title: "Open an image or a saved report",
                        message: "Choose a final ARM64 Mach-O image or app bundle. Review function coverage, modeled observations and the evidence behind each finding.")
                    HStack(spacing: 8) {
                        Button("Open Binary or App…", action: workspace.chooseBinary)
                            .buttonStyle(.borderedProminent)
                        Button("Open Audit Report…", action: workspace.chooseReport)
                        Spacer()
                    }.disabled(workspace.isBusy)
                }
                if let message = workspace.setupMessage {
                    SectionCard("Engine setup") {
                        LumenBanner(message, title: "Engine setup", tone: .info, systemImage: "wrench.and.screwdriver")
                        SettingsLink { Text("Open Settings…") }
                    }
                }
                SectionCard("What a result means") {
                    ForEach(AuditVerdict.allCases) { verdict in
                        VStack(alignment: .leading, spacing: 4) {
                            VerdictLabel(verdict: verdict)
                            Text(verdict.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("A modeled leaf-body observation does not establish asynchronous unwind validity. Coverage and limitations remain visible with each finding.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppDesign.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

extension AuditVerdict {
    var tint: Color {
        switch self {
        case .agreement: return .indigo
        case .inconsistency: return .orange
        case .unresolved: return .secondary
        }
    }

    var explanation: String {
        switch self {
        case .agreement:
            return "Metadata and the modeled state agree at the observations the engine could fully check."
        case .inconsistency:
            return "Concrete expected and observed state differ within the supported model."
        case .unresolved:
            return "Available metadata, instructions, or model coverage do not support a conclusion."
        }
    }
}

struct VerdictLabel: View {
    let verdict: AuditVerdict
    var body: some View {
        Label(verdict.title, systemImage: verdict.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(verdict.tint)
    }
}

struct SectionCard<Content: View>: View {

    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenCard(padding: AppDesign.Space.section)
    }
}

struct FactRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatTile: View {
    let value: Int
    let title: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value.formatted()).font(.title2.weight(.semibold)).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

func readableToken(_ value: String) -> String {
    if value == "modeled_leaf_body" { return "Modeled leaf body" }
    return value.replacingOccurrences(of: "_", with: " ").capitalized
}
