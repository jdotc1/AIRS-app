import SwiftUI
import LumenUI
import LumenTokens
import AIRSEntitlements

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
        .sheet(item: $fileOpen.intakeReview) { review in
            AppIntakeView(review: review,
                inspect: { fileOpen.confirmIntake(audit: audit, entitlements: entitlements, navigation: navigation) },
                unwind: { fileOpen.confirmIntake(unwind: true, audit: audit, entitlements: entitlements, navigation: navigation) },
                swap: fileOpen.swapIntake, cancel: { fileOpen.intakeReview = nil })
                .interactiveDismissDisabled()
        }
        .sheet(item: $fileOpen.archiveReview) { review in
            ArchiveReviewView(review: review,
                open: { _ = fileOpen.openArchiveAttachment($0, audit: audit, entitlements: entitlements, navigation: navigation) },
                cancel: fileOpen.cancelArchiveReview)
                .interactiveDismissDisabled()
        }
        .sheet(item: $fileOpen.inventoryReview) { review in
            ComponentInventoryView(review: review, status: fileOpen.status, isWriting: fileOpen.isWritingInventory,
                export: { fileOpen.chooseInventoryExport(audit: audit, entitlements: entitlements) }, close: fileOpen.closeInventory)
                .interactiveDismissDisabled()
        }
        .sheet(item:$fileOpen.projectReview) { session in
            ProjectReviewView(session:session,busy:fileOpen.isBusy,status:fileOpen.status,batchCandidates:projectBatchChoices,
                select:{fileOpen.selectProject($0,audit:audit,entitlements:entitlements)},
                create:{fileOpen.createProject($0,audit:audit,entitlements:entitlements)},
                rename:{fileOpen.renameProject($0,audit:audit,entitlements:entitlements)},
                add:{fileOpen.chooseProjectEvidence(audit:audit,entitlements:entitlements)},
                pin:{fileOpen.pinProjectBaseline($0,audit:audit,entitlements:entitlements)},
                note:{fileOpen.annotateProject($0,acknowledged:$1,audit:audit,entitlements:entitlements)},
                review:{fileOpen.reviewProjectEvidence($0,audit:audit,entitlements:entitlements)},
                export:{fileOpen.exportProjectEvidence($0,audit:audit,entitlements:entitlements)},
                exportMetadata:{fileOpen.exportProjectEvidence(nil,audit:audit,entitlements:entitlements)},
                remove:{fileOpen.removeProjectEvidence($0,audit:audit,entitlements:entitlements)},
                removeUnreferenced:{fileOpen.removeUnreferencedProjectEvidence($0,audit:audit,entitlements:entitlements)},
                removeProject:{fileOpen.removeProject($0,audit:audit,entitlements:entitlements)},
                link:{fileOpen.linkProjectBatch($0,audit:audit,entitlements:entitlements)},close:fileOpen.closeProjects)
                .interactiveDismissDisabled()
        }
        .sheet(item:$fileOpen.coverageReview) {session in
            CoverageReviewView(inventory:session.inventory,busy:fileOpen.isBusy,status:fileOpen.status,
                openObservation:{fileOpen.chooseCoverageObservation($0,reason:$1,audit:audit,entitlements:entitlements,navigation:navigation)},close:fileOpen.closeCoverage)
                .interactiveDismissDisabled()
        }
        .sheet(item:$fileOpen.policyReview) {session in
            PolicyReviewView(session:session,busy:fileOpen.isBusy,status:fileOpen.status,
                evaluate:fileOpen.evaluatePolicyReview,
                export:{fileOpen.chooseInventoryExport(audit:audit,entitlements:entitlements)},close:fileOpen.closePolicyReview)
                .interactiveDismissDisabled()
        }
        .sheet(item: $fileOpen.assessmentReview) { session in
            AssessmentReviewView(session:session,busy:fileOpen.isBusy,status:fileOpen.status,
                run:{fileOpen.runAssessment($0,audit:audit,entitlements:entitlements)},cancel:fileOpen.cancel,
                export:{fileOpen.chooseInventoryExport(audit:audit,entitlements:entitlements)},close:fileOpen.closeAssessment)
                .interactiveDismissDisabled()
        }
        .sheet(item: $fileOpen.componentPairReview, onDismiss: { fileOpen.componentPairDismissed(audit:audit,entitlements:entitlements) }) { pair in
            ComponentPairView(pair:pair,swap:fileOpen.swapComponentPair,cancel:{fileOpen.componentPairReview = nil},
                confirm:{fileOpen.confirmComponentPair($0,audit:audit,entitlements:entitlements)})
                .interactiveDismissDisabled()
        }
        .sheet(item: $fileOpen.componentReview) { session in
            ComponentReviewView(session:session,status:fileOpen.status,busy:fileOpen.isBusy,
                read:{fileOpen.readComponentEntitlements($0,audit:audit,entitlements:entitlements)},
                export:{fileOpen.chooseInventoryExport(audit:audit,entitlements:entitlements)},close:fileOpen.closeComponentReview)
                .interactiveDismissDisabled()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !fileOpen.blocksActions, !audit.blocksFileOpen, !entitlements.isBusy else { return false }
            fileOpen.open(urls, audit: audit, entitlements: entitlements, navigation: navigation)
            return true
        }
        .tint(palette[.accent])
    }
    private var projectBatchChoices:[ProjectBatchChoice] {
        var auditIDs=Set(audit.batchHistoryEntries.filter{$0.issue == nil}.map(\.id))
        if let snapshot=audit.batchSnapshot,snapshot.checkpointRevision != nil {auditIDs.insert(snapshot.id)}
        var entitlementIDs=Set(entitlements.batchHistoryEntries.filter{$0.issue == nil}.map(\.id))
        if let id=entitlements.batchCheckpoint?.historyRecordID {entitlementIDs.insert(id)}
        return auditIDs.sorted{$0.uuidString<$1.uuidString}.map{.init(family:.audit,historyID:$0)}
            + entitlementIDs.sorted{$0.uuidString<$1.uuidString}.map{.init(family:.entitlements,historyID:$0)}
    }
    private var isWorking: Bool {
        fileOpen.isBusy || (navigation.showsEntitlements ? entitlements.isWorking : audit.isBusy)
    }
    private var currentStatus: String {
        fileOpen.isBusy ? fileOpen.status : (navigation.showsEntitlements ? entitlements.status : audit.status)
    }
    private var cancelAction: (() -> Void)? {
        fileOpen.isBusy ? (fileOpen.canCancel ? fileOpen.cancel : nil) :
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
                    Menu {
                        Button("Complete JSON…", action: entitlements.chooseExport)
                        Button("Text Summary…", action: entitlements.chooseTextExport)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
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
