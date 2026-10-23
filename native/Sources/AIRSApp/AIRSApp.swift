import AppKit
import SwiftUI
import LumenTokens
import LumenUI

@main
@MainActor
struct AIRSApp: App {
    @NSApplicationDelegateAdaptor(AIRSApplicationDelegate.self) private var applicationDelegate
    @StateObject private var workspace: AuditWorkspace
    @State private var normalEntitlements: EntitlementsWorkspace?
    private var entitlements: EntitlementsWorkspace {
        guard let normalEntitlements else { preconditionFailure("Normal workspace requested during Settings review") }
        return normalEntitlements
    }
    private let settingsReview: SettingsReviewConfiguration?
    @State private var navigation = AIRSNavigation()
    @State private var normalFileOpen: AIRSFileOpen?
    private var fileOpen: AIRSFileOpen {
        guard let normalFileOpen else { preconditionFailure("File routing requested during Settings review") }
        return normalFileOpen
    }

    init() {
        let review: SettingsReviewConfiguration?
        do {
            review = try SettingsReviewConfiguration.parse(environment: ProcessInfo.processInfo.environment,
                                                            bundleIdentifier: Bundle.main.bundleIdentifier)
            if let review {
                let preferences = try review.preferences()
                _workspace = StateObject(wrappedValue: AuditWorkspace(recents: SettingsReviewRecents(),
                    supportRoot: review.root.appendingPathComponent("data", isDirectory: true),
                    preferences: preferences))
            } else {
                _workspace = StateObject(wrappedValue: AuditWorkspace())
            }
        } catch {
            fatalError("Isolated Settings review rejected: \(error); no production fallback")
        }
        settingsReview = review
        _normalEntitlements = State(initialValue: review == nil ? EntitlementsWorkspace() : nil)
        _normalFileOpen = State(initialValue: review == nil ? AIRSFileOpen() : nil)
        LumenThemeStore.install(LumenThemeStore(registry: LumenRegistry(packs: [.core]),
            configuration: LumenStoreConfiguration(appName: "AIRS",
                themesDirectory: review?.root.appendingPathComponent("themes", isDirectory: true),
                defaultThemeID: LumenThemes.standardID,
                defaultsSuiteName: review.map { $0.suite + ".lumen" })))
        #if DEBUG
        // Process-local review only; never changes system appearance or saved preferences.
        if ProcessInfo.processInfo.environment["AIRS_UI_REVIEW_APPEARANCE"] == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
    }

    var body: some Scene {
        Window("AIRS", id: "main") {
            if settingsReview == nil {
            AIRSWindowView(audit: workspace, entitlements: entitlements,
                           navigation: navigation, fileOpen: fileOpen)
                .lumenPaletteRoot()
                .lumenMetrics(.standard)
                .lumenDensityRoot()
                .frame(minWidth: 1000, minHeight: 660)
                .onAppear {
                    applicationDelegate.configureFileOpening(audit: workspace, entitlements: entitlements,
                        navigation: navigation, fileOpen: fileOpen)
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    workspace.refreshEngineAvailability()
                    fileOpen.configureProjectProtection(audit:workspace,entitlements:entitlements)
                }
                .alert("Open Report", isPresented: Binding(
                    get: { fileOpen.errorMessage != nil },
                    set: { if !$0 { fileOpen.errorMessage = nil } }
                )) { Button("OK") { fileOpen.errorMessage = nil } }
                message: { Text(fileOpen.errorMessage ?? "") }
            } else {
                #if DEBUG
                if let fixture = ProcessInfo.processInfo.environment["AIRS_COMPARISON_REVIEW_FIXTURE"] {
                    ComparisonReviewLauncher(workspace: workspace, fixture: URL(fileURLWithPath: fixture))
                } else {
                    SettingsReviewLauncher()
                }
                #else
                SettingsReviewLauncher()
                #endif
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                if settingsReview == nil {
                Button("Open Binary or App…") { navigation.showsEntitlements = false; workspace.chooseBinary() }
                    .keyboardShortcut("o")
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Open Report…") {
                    fileOpen.chooseReport(audit: workspace, entitlements: entitlements, navigation: navigation)
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Open Audit Report…") { navigation.showsEntitlements = false; workspace.chooseReport() }
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Menu("Open Recent Report") {
                    ForEach(workspace.recentReports, id: \.self) { url in
                        Button(url.lastPathComponent) { navigation.performAudit { workspace.importReport(url) } }
                    }
                    Divider()
                    Button("Clear Recent Reports", action: workspace.clearRecentReports)
                }
                .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions || workspace.recentReports.isEmpty)
                Button("Report Library") { navigation.performAudit { workspace.openLibrary() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Keep Current Report") { navigation.performAudit { workspace.keepCurrentReport() } }
                    .disabled(workspace.report == nil || workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Open Decoder Inventory…") {fileOpen.chooseDecodeInventory(audit:workspace,entitlements:entitlements)}
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                Button("Open Coverage Inventory…") {fileOpen.chooseCoverage(audit:workspace,entitlements:entitlements)}
                    .disabled(fileOpen.blocksActions || workspace.blocksFileOpen || entitlements.isBusy)
                Button("Review Owned Build Policy…") {fileOpen.choosePolicyReview(audit:workspace,entitlements:entitlements)}
                    .disabled(fileOpen.blocksActions || workspace.blocksFileOpen || entitlements.isBusy)
                Button("Inspection Projects…") {fileOpen.openProjects(audit:workspace,entitlements:entitlements)}
                    .disabled(fileOpen.blocksActions || workspace.blocksFileOpen || entitlements.isBusy)
                Button("Assess App Signature and Distribution…") {fileOpen.chooseAssessment(audit:workspace,entitlements:entitlements)}
                    .disabled(fileOpen.blocksActions || workspace.blocksFileOpen || entitlements.isBusy)
                Button("Compare App Components…") { fileOpen.chooseComponentComparison(audit:workspace,entitlements:entitlements) }
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                Button("Inventory App Components…") { fileOpen.chooseInventory(audit: workspace, entitlements: entitlements) }
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                Button("Discover App Images…") { navigation.performAudit { workspace.chooseBundleDiscovery() } }
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions || workspace.hasUnsavedBatchHistory)
                Button("Analyze Selected Images…") { navigation.performAudit { workspace.chooseBatch() } }
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions || workspace.hasUnretainedBatchReports)
                Button("Batch Results") { navigation.performAudit { workspace.showBatchResults() } }
                    .disabled(workspace.batchSnapshot == nil || entitlements.isBusy || fileOpen.blocksActions)
                Button("Batch History") { navigation.performAudit { workspace.openBatchHistory() } }
                    .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions || workspace.hasUnsavedBatchHistory)
                }
            }
            CommandMenu("Entitlements") {
                if settingsReview == nil {
                Button("Compare Entitlements") {
                    navigation.select(.entitlements, audit: workspace, entitlements: entitlements, fileOpen: fileOpen)
                }
                    .disabled(!navigation.canSelectDestination(audit: workspace, entitlements: entitlements, fileOpen: fileOpen))
                Button("Find Entitlement…") {
                    guard navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) else { return }
                    entitlements.beginFindEntitlement()
                }
                    .keyboardShortcut(navigation.showsEntitlements ? KeyboardShortcut("f", modifiers: .command) : nil)
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || !entitlements.canFindEntitlement)
                Button("Previous Change") {
                    guard navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) else { return }
                    entitlements.moveToChange(.previous)
                }
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || !entitlements.canMoveToChange(.previous))
                Button("Next Change") {
                    guard navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) else { return }
                    entitlements.moveToChange(.next)
                }
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || !entitlements.canMoveToChange(.next))
                Divider()
                Button("Open Entitlement Report…") {
                    navigation.showsEntitlements = true; entitlements.chooseSavedReport()
                }.disabled(entitlements.isBusy || fileOpen.blocksActions)
                Button("Batch Entitlement Comparisons", action: entitlements.openBatch)
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || entitlements.isBusy)
                Button("Entitlement Batch History") { entitlements.openBatchHistory() }
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || entitlements.isBusy)
                Button("Entitlement Report Library") { entitlements.openLibrary() }
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || entitlements.isBusy)
                Button("Keep Current Entitlement Report") { entitlements.keepCurrentReport() }
                    .disabled(!navigation.allowsEntitlementNavigation(audit: workspace, fileOpen: fileOpen) || entitlements.isBusy || entitlements.model.report == nil)
                Button("Export Entitlement JSON…", action: entitlements.chooseExport)
                    .disabled(entitlements.isBusy || fileOpen.blocksActions || entitlements.model.report == nil)
                Button("Export Entitlement Text Summary…", action: entitlements.chooseTextExport)
                    .disabled(entitlements.isBusy || fileOpen.blocksActions || entitlements.model.report == nil)
                }
            }
            CommandMenu("Analysis") {
                if settingsReview == nil {
                Button("Attach dSYM…") { navigation.performAudit { workspace.chooseDSYM() } }
                    .disabled(workspace.report == nil || workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Export Audit JSON…") { navigation.performAudit { workspace.exportCurrentReport() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(workspace.report == nil || workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Compare Baseline…") { navigation.performAudit { workspace.chooseBaseline() } }
                    .disabled(workspace.report == nil || workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                Button("Import Consumer Acknowledgment…") { navigation.performAudit { workspace.chooseConsumerAcknowledgment() } }
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                Button("Retain Bound Request Archive…") { navigation.performAudit { workspace.chooseBoundRequestArchive() } }
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                Button("Review Consumer Acknowledgments") { navigation.performAudit { workspace.reviewConsumerAcknowledgments() } }
                    .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                if let finding = workspace.selectedFinding {
                    Button("Export Selected Bound Review…") { navigation.performAudit { workspace.exportBoundRequest(finding) } }
                        .disabled(workspace.blocksFileOpen || entitlements.isBusy || fileOpen.blocksActions)
                    Button("Export Selected Handoff JSON…") { navigation.performAudit { workspace.exportHandoff(finding) } }
                        .disabled(workspace.isBusy || entitlements.isBusy || fileOpen.blocksActions)
                }
                Divider()
                Button("Cancel Operation", action: workspace.cancel)
                    .keyboardShortcut(".")
                    .disabled(!workspace.canCancel)
                }
            }
        }

        Settings {
            EngineSettingsView(workspace: workspace).disabled(normalFileOpen?.blocksActions ?? false)
                .lumenPaletteRoot()
                .lumenMetrics(.standard)
                .lumenDensityRoot()
        }
        .lumenSettingsScene()
        .defaultSize(width: LumenSettingsSidebarView.windowIdealWidth,
                     height: EngineSettingsView.idealHeight)
    }
}

@MainActor
final class AIRSApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: AuditWorkspace?
    weak var entitlements: EntitlementsWorkspace?
    private var awaitingTermination = false
    weak var fileOpen: AIRSFileOpen?
    private weak var navigation: AIRSNavigation?
    private var startupURLs: [URL]?

    func configureFileOpening(audit: AuditWorkspace, entitlements: EntitlementsWorkspace,
                              navigation: AIRSNavigation, fileOpen: AIRSFileOpen) {
        workspace = audit; self.entitlements = entitlements
        self.navigation = navigation; self.fileOpen = fileOpen
        if let urls = startupURLs {
            startupURLs = nil
            receiveOpenURLs(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) { receiveOpenURLs(urls) }

    func receiveOpenURLs(_ urls: [URL]) {
        guard let workspace, let entitlements, let navigation, let fileOpen else {
            // One bounded cold-start event; multiple early events are rejected together.
            startupURLs = startupURLs == nil ? Array(urls.prefix(2)) : []
            return
        }
        fileOpen.open(urls, audit: workspace, entitlements: entitlements, navigation: navigation)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace?.requiresQuitSettlement == true || entitlements?.requiresQuitSettlement == true || fileOpen?.blocksActions == true else { return .terminateNow }
        if !awaitingTermination {
            awaitingTermination = true
            Task {
                let shouldQuit = await settleBeforeQuit()
                awaitingTermination = false
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    /// Keep refusal visible even when a pending entitlement report is off-screen.
    func settleBeforeQuit() async -> Bool {
        let fileReady = await fileOpen?.finishBeforeQuit() ?? true
        guard fileReady else { fileOpen?.resumeAfterCancelledQuit(); return false }
        let entitlementReady = await entitlements?.finishBeforeQuit() ?? true
        let shouldQuit: Bool
        if entitlementReady {
            shouldQuit = await workspace?.finishBeforeQuit() ?? true
            if !shouldQuit { entitlements?.resumeAfterCancelledQuit() }
        } else {
            navigation?.showsEntitlements = true
            shouldQuit = false
        }
        if !shouldQuit { fileOpen?.resumeAfterCancelledQuit() }
        return shouldQuit
    }

}
