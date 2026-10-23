import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class ComponentInventoryWorkspaceTests: XCTestCase {
    private func fixture() -> ComponentInventory {
        .init(scope: .init(searchedLocations: ["Contents/MacOS"], completion: .partial, exclusions: [], issues: ["Owned missing metadata"]),
            components: [.init(relativePath: "Contents/MacOS/Main", kind: "app", architectures: ["x86_64"], readIssues: ["Minimum unavailable"])])
    }
    @MainActor
    func testBuildStagesInventoryWithoutReplacingSessionsAndCancelSettles() async throws {
        let inventory = fixture(), audit = AuditWorkspace(), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let owner = AIRSFileOpen(hasModal: { false }, inventoryBuild: { _ in .init(inventory: inventory, units: [:]) })
        let auditRevision = audit.reportRevision, entitlementRevision = entitlements.model.reportRevision
        await owner.inventory(URL(fileURLWithPath: "/owned/App.app"), audit: audit, entitlements: entitlements)?.value
        XCTAssertEqual(owner.inventoryReview?.inventory.id, inventory.id)
        XCTAssertEqual(audit.reportRevision, auditRevision)
        XCTAssertEqual(entitlements.model.reportRevision, entitlementRevision)
        XCTAssertTrue(owner.blocksActions)
        owner.closeInventory()
        XCTAssertFalse(owner.blocksActions)
        let task = try XCTUnwrap(owner.inventory(URL(fileURLWithPath: "/owned/App.app"), audit: audit, entitlements: entitlements))
        owner.cancel()
        await task.value
        XCTAssertNil(owner.inventoryReview)
        XCTAssertFalse(owner.isBusy)
        _ = navigation
    }
    @MainActor
    func testArchiveInventoryRequiresExplicitSelection() async throws {
        let data = try ComponentInventoryDocumentCodec.archive(fixture())
        let owner = AIRSFileOpen(read: { _ in try AIRSOpenedReport.parse(data) }, hasModal: { false })
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        await owner.open([URL(fileURLWithPath: "/owned/inventory.airsreview")], audit: audit, entitlements: entitlements, navigation: navigation)?.value
        XCTAssertNil(owner.inventoryReview)
        let review = try XCTUnwrap(owner.archiveReview)
        await owner.openArchiveAttachment(review.archive.attachments[0].id, audit: audit, entitlements: entitlements, navigation: navigation)?.value
        XCTAssertEqual(owner.inventoryReview?.archiveBytes, data)
        XCTAssertNil(owner.archiveReview)
        XCTAssertFalse(owner.inventoryReview?.inventory.observedIntelOnly.isEmpty ?? true)
    }
    @MainActor
    func testChangedSessionRejectsLateInventoryAndProtectedExportDoesNotWrite() async throws {
        let inventory = fixture(), audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        let owner = AIRSFileOpen(hasModal: { false }, inventoryBuild: { _ in .init(inventory: inventory, units: [:]) })
        let task = try XCTUnwrap(owner.inventory(URL(fileURLWithPath: "/owned/App.app"), audit: audit, entitlements: entitlements))
        entitlements.model.loadExample()
        let changed = entitlements.model.reportRevision
        await task.value
        XCTAssertNil(owner.inventoryReview)
        XCTAssertEqual(entitlements.model.reportRevision, changed)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-components-20261020/protected/\(UUID())/Selected.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        await owner.inventory(root, audit: audit, entitlements: entitlements)?.value
        let output = root.appendingPathComponent("Contents/forbidden.airsreview")
        let write = owner.exportInventory(to: output, audit: audit, entitlements: entitlements)
        XCTAssertNil(write)
        await write?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNotNil(owner.inventoryReview)
    }
    @MainActor
    func testWriteFailureDuringQuitPreservesInventoryAndRefusesQuit() async throws {
        let inventory = fixture(), audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        let gate = ComponentWriteGate()
        let owner = AIRSFileOpen(hasModal: { false }, inventoryBuild: { _ in .init(inventory: inventory, units: [:]) }, inventoryWrite: { _,_ in try await gate.write() })
        await owner.inventory(URL(fileURLWithPath: "/owned/App.app"), audit: audit, entitlements: entitlements)?.value
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-components-20261020/failure.airsreview")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let writing = try XCTUnwrap(owner.exportInventory(to: output, audit: audit, entitlements: entitlements))
        await gate.started()
        let quitting = Task { await owner.finishBeforeQuit() }
        while !owner.isTerminating { await Task.yield() }
        owner.cancel()
        await gate.fail()
        await writing.value
        let quit = await quitting.value
        XCTAssertFalse(quit)
        XCTAssertNotNil(owner.inventoryReview)
        XCTAssertFalse(owner.isBusy)
        owner.resumeAfterCancelledQuit()
        owner.closeInventory()
        XCTAssertFalse(owner.blocksActions)
    }
}
private actor ComponentWriteGate {
    var continuation: CheckedContinuation<Void, Error>?
    var waiter: CheckedContinuation<Void, Never>?
    func write() async throws {
        try await withCheckedThrowingContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async { if continuation == nil { await withCheckedContinuation { waiter = $0 } } }
    func fail() { continuation?.resume(throwing: CocoaError(.fileWriteNoPermission)); continuation = nil }
}
