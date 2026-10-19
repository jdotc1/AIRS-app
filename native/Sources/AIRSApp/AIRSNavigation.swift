import Observation

/// One AIRS window owns navigation for both workspaces and their commands.
@Observable
@MainActor
final class AIRSNavigation {
    var showsEntitlements = false
    func allowsEntitlementNavigation(audit: AuditWorkspace, fileOpen: AIRSFileOpen) -> Bool {
        showsEntitlements && !audit.blocksFileOpen && !fileOpen.blocksActions && fileOpen.errorMessage == nil
    }
    func performAudit(_ action: () -> Void) {
        showsEntitlements = false
        action()
    }
}

enum AIRSDestination: String, Hashable, CaseIterable, Identifiable {
    case audit, auditBatch, auditHistory, auditLibrary
    case entitlements, entitlementBatch, entitlementHistory, entitlementLibrary, entitlementRecovery
    var id: Self { self }
    var title: String {
        switch self {
        case .audit: return "Unwind Analysis"
        case .entitlements: return "Compare Entitlements"
        case .auditBatch: return "Image Batches"
        case .entitlementBatch: return "Comparison Queue"
        case .auditHistory, .entitlementHistory: return "Batch History"
        case .auditLibrary, .entitlementLibrary: return "Report Library"
        case .entitlementRecovery: return "Recovery"
        }
    }
    var symbol: String {
        switch self {
        case .audit: return AppDesign.Symbol.audit
        case .entitlements: return AppDesign.Symbol.entitlements
        case .auditBatch, .entitlementBatch: return AppDesign.Symbol.batch
        case .auditHistory, .entitlementHistory: return AppDesign.Symbol.history
        case .auditLibrary, .entitlementLibrary: return AppDesign.Symbol.library
        case .entitlementRecovery: return AppDesign.Symbol.recovery
        }
    }
}

extension AIRSNavigation {
    func destination(audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> AIRSDestination {
        if showsEntitlements {
            if entitlements.showingBatchRecovery { return .entitlementRecovery }
            if entitlements.showingBatchHistory { return .entitlementHistory }
            if entitlements.showingBatch { return .entitlementBatch }
            if entitlements.showingLibrary { return .entitlementLibrary }
            return .entitlements
        }
        if audit.showingBatchHistory { return .auditHistory }
        if audit.showingBatch { return .auditBatch }
        if audit.showingLibrary { return .auditLibrary }
        return .audit
    }

    func canSelectDestination(audit: AuditWorkspace, entitlements: EntitlementsWorkspace, fileOpen: AIRSFileOpen) -> Bool {
        !audit.blocksWorkspaceNavigation && !entitlements.isBusy && entitlements.errorMessage == nil &&
            !fileOpen.blocksActions && fileOpen.errorMessage == nil
    }

    func select(_ destination: AIRSDestination, audit: AuditWorkspace,
                entitlements: EntitlementsWorkspace, fileOpen: AIRSFileOpen) {
        guard canSelectDestination(audit: audit, entitlements: entitlements, fileOpen: fileOpen) else { return }
        // A failed checkpoint must retain a visible route to its settlement controls.
        guard !audit.hasUnsavedBatchHistory || destination == .auditBatch else { return }
        switch destination {
        case .audit:
            showsEntitlements = false
            audit.showingBatch = false; audit.showingBatchHistory = false; audit.showingLibrary = false
        case .auditBatch: showsEntitlements = false; audit.showBatchResults()
        case .auditHistory: showsEntitlements = false; audit.openBatchHistory()
        case .auditLibrary: showsEntitlements = false; audit.openLibrary()
        case .entitlements: showsEntitlements = true; entitlements.showComparison()
        case .entitlementBatch: showsEntitlements = true; entitlements.openBatch()
        case .entitlementHistory: showsEntitlements = true; entitlements.openBatchHistory()
        case .entitlementLibrary: showsEntitlements = true; entitlements.openLibrary()
        case .entitlementRecovery: showsEntitlements = true; entitlements.openBatchRecovery()
        }
    }
}
