import SwiftUI
import LumenUI
import LumenTokens

/// One persistent shell for both workflows. Child pages own evidence, never window chrome.
struct AIRSWindowView: View {
    @ObservedObject var audit: AuditWorkspace
    @Bindable var entitlements: EntitlementsWorkspace
    @Bindable var navigation: AIRSNavigation
    @Bindable var fileOpen: AIRSFileOpen

    @Environment(\.lumenPalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                AIRSSidebar(audit: audit, entitlements: entitlements, navigation: navigation, fileOpen: fileOpen)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 250)
            } detail: {
                VStack(spacing: 0) {
                    if navigation.showsEntitlements {
                        EntitlementsView(workspace: entitlements,
                            navigationAllowed: navigation.allowsEntitlementNavigation(audit: audit, fileOpen: fileOpen))
                    } else {
                        WorkspaceView(workspace: audit)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(palette[.bgCanvas])
                .disabled(fileOpen.blocksActions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(navigation.showsEntitlements ? "Entitlements" : "Unwind Analysis")
            .toolbar { AIRSWindowToolbar(audit: audit, entitlements: entitlements,
                                         navigation: navigation, fileOpen: fileOpen) }
            LumenStatusBar {
                if isWorking { ProgressView().controlSize(.mini) }
                Text(currentStatus).lineLimit(1).help(currentStatus)
                Spacer(minLength: Lumen.Space.s4)
                if let cancel = cancelAction { Button("Cancel", action: cancel).controlSize(.mini) }
                Text("Local workspace")
            }
            .padding(.horizontal, Lumen.Space.s2)
            .padding(.vertical, Lumen.Space.s1)

        }
        .tint(palette[.accent])
    }
    private var isWorking: Bool {
        fileOpen.isBusy || (navigation.showsEntitlements ? entitlements.isWorking : audit.isBusy)
    }
    private var currentStatus: String {
        fileOpen.isBusy ? fileOpen.status : (navigation.showsEntitlements ? entitlements.status : audit.status)
    }
    private var cancelAction: (() -> Void)? {
        fileOpen.isBusy ? fileOpen.cancel :
            (navigation.showsEntitlements ? (entitlements.canCancel ? entitlements.cancel : nil) :
                (audit.isBusy && audit.canCancel ? audit.cancel : nil))
    }

}

private struct AIRSSidebar: View {
    @ObservedObject var audit: AuditWorkspace
    @Bindable var entitlements: EntitlementsWorkspace
    @Bindable var navigation: AIRSNavigation
    @Bindable var fileOpen: AIRSFileOpen

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                LumenSidebarSection("Unwind") {
                    rows([.audit, .auditBatch, .auditHistory, .auditLibrary])
                }
                LumenSidebarSection("Entitlements") {
                    rows([.entitlements, .entitlementBatch, .entitlementHistory, .entitlementLibrary, .entitlementRecovery])
                }
            }
        }
        .lumenSidebarBackground()
        .disabled(!navigation.canSelectDestination(audit: audit, entitlements: entitlements, fileOpen: fileOpen))
        .safeAreaInset(edge: .bottom) {
            Label("AIRS · Local evidence", systemImage: "internaldrive")
                .font(Lumen.Font.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Lumen.Space.s5)
        }
    }

    private func rows(_ destinations: [AIRSDestination]) -> some View {
        VStack(spacing: Lumen.Space.s1) {
            ForEach(destinations) { destination in
                let item = LumenSidebarItem(id: destination.rawValue, title: destination.title,
                                           systemImage: destination.symbol)
                Button {
                    navigation.select(destination, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
                } label: {
                    LumenListRow(item.title, systemImage: item.systemImage, hue: item.hue,
                        isSelected: navigation.destination(audit: audit, entitlements: entitlements) == destination,
                        context: .sidebar) { EmptyView() }
                }
                .buttonStyle(.plain)
                .disabled(audit.hasUnsavedBatchHistory && destination != .auditBatch)
            }
        }.padding(Lumen.Space.s2)
    }
}

private struct AIRSWindowToolbar: ToolbarContent {
    @ObservedObject var audit: AuditWorkspace
    @Bindable var entitlements: EntitlementsWorkspace
    @Bindable var navigation: AIRSNavigation
    @Bindable var fileOpen: AIRSFileOpen

    var body: some ToolbarContent {
        // One native toolbar item keeps AppKit from splitting or relocating individual actions.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: Lumen.Space.s5) {
                HStack(spacing: Lumen.Space.s5) {
                    Menu {
                        if navigation.showsEntitlements {
                            if navigation.destination(audit: audit, entitlements: entitlements) == .entitlements {
                                Button("Previous App…") { entitlements.choose(.previous) }
                                Button("Current App…") { entitlements.choose(.current) }
                                Divider()
                            } else if navigation.destination(audit: audit, entitlements: entitlements) == .entitlementBatch {
                                Button("Batch Manifest…", action: entitlements.chooseBatchManifest)
                                    .disabled(!entitlements.canImportBatchManifest)
                                Divider()
                            }
                            Button("Saved Comparison…", action: entitlements.chooseSavedReport)
                        } else {
                            Button("Binary or App…", action: audit.chooseBinary)
                            Button("Audit Report…", action: audit.chooseReport)
                            Divider()
                            Button("Discover App Images…", action: audit.chooseBundleDiscovery)
                            Button("Analyze Selected Images…", action: audit.chooseBatch)
                                .disabled(audit.hasUnretainedBatchReports)
                        }
                    } label: { HStack(spacing: 5) { Image(systemName: "folder"); Text("Open") }.fixedSize() }
                    .disabled(audit.isBusy || entitlements.isBusy || fileOpen.blocksActions || audit.hasUnsavedBatchHistory)
                    Menu {
                        if navigation.showsEntitlements {
                            Button("Swap Previous and Current", action: entitlements.swap)
                                .disabled(!entitlements.model.canSwap)
                            Button("Keep Current Comparison") { entitlements.keepCurrentReport() }
                                .disabled(entitlements.model.report == nil)
                            Divider()
                            Button("Clear Comparison", action: { entitlements.clear() })
                                .disabled(entitlements.model.previous.isEmpty && entitlements.model.current.isEmpty)
                        } else {
                            Button("Attach dSYM…", action: audit.chooseDSYM).disabled(audit.report == nil)
                            Button("Compare Baseline…", action: audit.chooseBaseline).disabled(audit.report == nil)
                            Button("Keep Current Report", action: audit.keepCurrentReport).disabled(audit.report == nil)
                        }
                    } label: { HStack(spacing: 5) { Image(systemName: "ellipsis.circle"); Text("Actions") }.fixedSize() }
                    .disabled(audit.isBusy || entitlements.isBusy || fileOpen.blocksActions ||
                              (navigation.showsEntitlements
                               ? navigation.destination(audit: audit, entitlements: entitlements) != .entitlements
                               : navigation.destination(audit: audit, entitlements: entitlements) != .audit))
                }
                LumenToolbarDivider()
                if navigation.showsEntitlements {
                    Button("Export", systemImage: "square.and.arrow.up", action: entitlements.chooseExport)
                        .disabled(entitlements.isBusy || fileOpen.blocksActions || entitlements.model.report == nil ||
                                  navigation.destination(audit: audit, entitlements: entitlements) != .entitlements)
                } else {
                    Button("Export", systemImage: "square.and.arrow.up", action: audit.exportCurrentReport)
                        .disabled(audit.isBusy || fileOpen.blocksActions || audit.report == nil ||
                                  navigation.destination(audit: audit, entitlements: entitlements) != .audit)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .labelStyle(.titleAndIcon)
            .controlSize(.regular)
        }
    }
}
