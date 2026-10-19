import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSApp

@MainActor private final class InterfaceRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
    func clearRecentDocuments() { recentDocumentURLs = [] }
}

final class UnifiedWorkspaceNavigationTests: XCTestCase {
    @MainActor
    func testSidebarRoundTripPreservesBothReportsAndQueuedPairIdentity() throws {
        let audit = AuditWorkspace(recents: InterfaceRecents())
        let entitlements = EntitlementsWorkspace()
        let navigation = AIRSNavigation(), fileOpen = AIRSFileOpen(hasModal: { false })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("examples/before.audit.json")
        let data = try Data(contentsOf: url), report = try AuditReport.decode(data)
        audit.openValidatedReport(report, data: data, from: url)
        let auditSelection = audit.selection
        entitlements.loadExample()
        let revision = entitlements.model.reportRevision
        let comparison = try XCTUnwrap(entitlements.model.report).jsonData()
        entitlements.addBatchPair(previous: URL(fileURLWithPath: "/Example/Before.app", isDirectory: true),
                                  current: URL(fileURLWithPath: "/Example/After.app", isDirectory: true), architecture: .arm64)
        let pairIDs = entitlements.batchPairs.map(\.id)
        navigation.select(.entitlementBatch, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .entitlementBatch)
        navigation.select(.auditBatch, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .auditBatch)
        XCTAssertNil(audit.batchSnapshot, "Opening the batch page must not start an analysis")
        navigation.select(.audit, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .audit)
        XCTAssertEqual(audit.report?.image.sliceSHA256, report.image.sliceSHA256)
        XCTAssertEqual(audit.selection, auditSelection)
        navigation.select(.entitlements, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .entitlements)
        XCTAssertFalse(entitlements.showingBatch)
        XCTAssertEqual(entitlements.batchPairs.map(\.id), pairIDs)
        XCTAssertEqual(entitlements.model.reportRevision, revision)
        XCTAssertEqual(try entitlements.model.report?.jsonData(), comparison)
        XCTAssertNil(entitlements.batchResult)
    }

    @MainActor
    func testSidebarCannotHideAnActiveReviewOrOutstandingError() throws {
        let audit = AuditWorkspace(recents: InterfaceRecents()), entitlements = EntitlementsWorkspace()
        let navigation = AIRSNavigation(), fileOpen = AIRSFileOpen(hasModal: { false })
        navigation.showsEntitlements = true
        entitlements.loadExample(); entitlements.beginFindEntitlement()
        let session = try XCTUnwrap(entitlements.entitlementFind)
        navigation.select(.auditBatch, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertTrue(navigation.showsEntitlements)
        XCTAssertFalse(audit.showingBatch)
        XCTAssertEqual(entitlements.entitlementFind?.id, session.id)
        entitlements.cancelFindEntitlement(sessionID: session.id)
        audit.showingError = true
        XCTAssertFalse(navigation.canSelectDestination(audit: audit, entitlements: entitlements, fileOpen: fileOpen))
        audit.showingError = false; fileOpen.errorMessage = "Unresolved file error"
        navigation.select(.audit, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertTrue(navigation.showsEntitlements)
        fileOpen.errorMessage = nil; entitlements.errorMessage = "Unresolved comparison error"
        XCTAssertFalse(navigation.canSelectDestination(audit: audit, entitlements: entitlements, fileOpen: fileOpen))
    }

    @MainActor
    func testSelectionReflectsExistingCommandAndFileRoutingState() {
        let audit = AuditWorkspace(recents: InterfaceRecents()), entitlements = EntitlementsWorkspace()
        let navigation = AIRSNavigation()
        audit.showingLibrary = true
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .auditLibrary)
        audit.showingBatchHistory = true
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .auditHistory)
        navigation.showsEntitlements = true; entitlements.openBatch()
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .entitlementBatch)
        entitlements.showComparison()
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .entitlements)
        navigation.performAudit { audit.showingLibrary = false; audit.showingBatchHistory = false }
        XCTAssertEqual(navigation.destination(audit: audit, entitlements: entitlements), .audit)
    }
    @MainActor
    func testUnsavedAuditCheckpointCanReturnToSettlementWithoutStartingWork() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("build/ui-overhaul/navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("owned.input"), libraryURL = root.appendingPathComponent("library")
        try Data("Owned input; never executed".utf8).write(to: input)
        try Data().write(to: libraryURL) // Retention must fail, keeping complete bytes pending.
        let raw = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        let audit = AuditWorkspace(library: ReportLibrary(root: libraryURL), recents: InterfaceRecents(),
            batchAudit: { _ in raw }, batchHistory: BatchHistory(root: root.appendingPathComponent("history"),
                                                               maximumRecoveryBytes: raw.count - 1))
        audit.startBatch([input])
        for _ in 0..<500 {
            if !audit.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(audit.isBusy)
        XCTAssertTrue(audit.hasUnsavedBatchHistory)
        let snapshot = try XCTUnwrap(audit.batchSnapshot)
        audit.showingBatch = false // The prior page's Done action.
        let entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let fileOpen = AIRSFileOpen(hasModal: { false })
        navigation.select(.entitlements, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertFalse(navigation.showsEntitlements, "Other destinations cannot hide unsettled audit history")
        navigation.select(.auditBatch, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertTrue(audit.showingBatch)
        XCTAssertEqual(audit.batchSnapshot?.id, snapshot.id)
        XCTAssertEqual(audit.batchSnapshot?.items.first?.unretainedData, raw)
        XCTAssertTrue(audit.hasUnsavedBatchHistory)
        XCTAssertFalse(audit.isBusy, "Returning to settlement does not replay work")
        audit.showingBatch = false; audit.showingError = true
        navigation.select(.auditBatch, audit: audit, entitlements: entitlements, fileOpen: fileOpen)
        XCTAssertFalse(audit.showingBatch, "An active error presentation must still block navigation")
    }

}
