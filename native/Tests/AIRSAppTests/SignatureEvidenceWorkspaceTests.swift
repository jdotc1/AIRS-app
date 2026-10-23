import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class SignatureEvidenceWorkspaceTests: XCTestCase {
    @MainActor
    func testExplicitCapturePreservesInventoryAndSessionsAndAddsBoundArchiveEvidence() async throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        let owner = AIRSFileOpen(hasModal: { false })
        let auditRevision = audit.reportRevision, entitlementRevision = entitlements.model.reportRevision
        await owner.inventory(app, audit: audit, entitlements: entitlements)?.value
        let before = try XCTUnwrap(owner.inventoryReview)
        let component = try XCTUnwrap(before.inventory.components.first)
        XCTAssertTrue(before.canCaptureSignature(component.id))
        let original = try InspectionArchive.decode(before.archiveBytes)
        await owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements)?.value
        let after = try XCTUnwrap(owner.inventoryReview)
        let document = try XCTUnwrap(after.signatureEvidence[component.id])
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(document.evidence.componentID, component.id)
        XCTAssertEqual(document.evidence.componentRelativePath, component.relativePath)
        XCTAssertEqual(document.evidence.containerSHA256.count, 64)
        XCTAssertEqual(document.evidence.slices.first?.state, .signatureAbsent)
        XCTAssertEqual(audit.reportRevision, auditRevision)
        XCTAssertEqual(entitlements.model.reportRevision, entitlementRevision)
        let archive = try InspectionArchive.decode(after.archiveBytes)
        XCTAssertEqual(archive.attachments.count, original.attachments.count + 1)
        XCTAssertEqual(archive.attachments.first?.bytes, original.attachments.first?.bytes)
        let item = try XCTUnwrap(archive.attachments.first { $0.kind == CodeSignatureEvidenceDocument.kind })
        XCTAssertTrue(archive.components.first { $0.id == component.id }?.evidenceIDs.contains(item.id) == true)
        XCTAssertFalse(after.canCaptureSignature(component.id))
        XCTAssertNil(owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements))
        XCTAssertNil(owner.exportInventory(to: app.appendingPathComponent("overwrite.airsreview"), audit: audit, entitlements: entitlements))
    }

    @MainActor
    func testSavedEvidenceRequiresExplicitAttachmentSelectionAndCannotAuthorizeLiveCapture() async throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let captureOwner = AIRSFileOpen(hasModal: { false })
        await captureOwner.inventory(app, audit: audit, entitlements: entitlements)?.value
        let component = try XCTUnwrap(captureOwner.inventoryReview?.inventory.components.first)
        await captureOwner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements)?.value
        let review = try XCTUnwrap(captureOwner.inventoryReview)
        let owner = AIRSFileOpen(read: { _ in try AIRSOpenedReport.parse(review.archiveBytes) }, hasModal: { false })
        let savedURL = app.deletingLastPathComponent().appendingPathComponent("saved.airsreview")
        await owner.open([savedURL], audit: audit, entitlements: entitlements, navigation: navigation)?.value
        XCTAssertNil(owner.signatureEvidenceReview)
        let archiveReview = try XCTUnwrap(owner.archiveReview)
        let attachment = try XCTUnwrap(archiveReview.archive.attachments.first { $0.kind == CodeSignatureEvidenceDocument.kind })
        await owner.openArchiveAttachment(attachment.id, audit: audit, entitlements: entitlements, navigation: navigation)?.value
        let historical = try XCTUnwrap(owner.signatureEvidenceReview)
        XCTAssertEqual(historical.archiveBytes, review.archiveBytes)
        XCTAssertEqual(historical.document.evidence.componentID, component.id)
        XCTAssertNil(owner.inventoryReview)
        XCTAssertTrue(owner.blocksActions)
        XCTAssertNil(owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements))
        guard case .signatureEvidence(let direct, _) = try AIRSOpenedReport.parse(historical.document.data()) else {
            return XCTFail("Standalone signature evidence must have an explicit supported route")
        }
        XCTAssertEqual(direct.evidence.containerSHA256, historical.document.evidence.containerSHA256)
        var originalBytes = try historical.document.data()
        originalBytes.append(contentsOf: [10, 32])
        let wrapped = try AIRSFileOpen.projectArchive(originalBytes)
        let retained = try InspectionArchive.decode(wrapped)
        XCTAssertEqual(retained.attachments.first?.bytes, originalBytes)
        XCTAssertEqual(try AIRSFileOpen.projectArchive(originalBytes), wrapped)
        XCTAssertEqual(retained.components.first?.id, component.id)
        owner.closeSignatureEvidence()
        XCTAssertFalse(owner.blocksActions)

        let imported = ComponentInventoryReview(inventory: review.inventory, archiveBytes: review.archiveBytes,
            sourceURL: savedURL, imported: true)
        XCTAssertFalse(imported.canCaptureSignature(component.id))
    }

    @MainActor
    func testEvidenceFromAnotherComponentCannotBeAttachedToLiveInventory() async throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let live = try ComponentInventoryBuilder().capture(app)
        let component = try XCTUnwrap(live.inventory.components.first)
        let unit = try XCTUnwrap(live.units[component.id])
        let unrelated = try CodeSignatureEvidenceDocument.capture(unit: unit, componentID: UUID())
        var review = ComponentInventoryReview(inventory: live.inventory,
            archiveBytes: try ComponentInventoryDocumentCodec.archive(live.inventory), sourceURL: app, imported: false, live: live)
        let bytes = review.archiveBytes
        XCTAssertThrowsError(try review.addSignatureEvidence(unrelated))
        XCTAssertEqual(review.archiveBytes, bytes)
        XCTAssertTrue(review.signatureEvidence.isEmpty)
    }

    @MainActor
    func testLateCaptureAfterWorkspaceChangeDoesNotPublishOrReplaceArchive() async throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let gate = SignatureWorkspaceGate()
        let owner = AIRSFileOpen(hasModal: { false }, signatureCapture: { unit, id in
            let result = try CodeSignatureEvidenceDocument.capture(unit: unit, componentID: id)
            await gate.wait()
            return result
        })
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        await owner.inventory(app, audit: audit, entitlements: entitlements)?.value
        let before = try XCTUnwrap(owner.inventoryReview)
        let component = try XCTUnwrap(before.inventory.components.first)
        let task = try XCTUnwrap(owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements))
        await gate.started()
        entitlements.model.loadExample()
        await gate.release()
        await task.value
        XCTAssertTrue(owner.inventoryReview?.signatureEvidence.isEmpty == true)
        XCTAssertEqual(owner.inventoryReview?.archiveBytes, before.archiveBytes)
        XCTAssertFalse(owner.isBusy)
        XCTAssertTrue(owner.status.contains("Workspace changed"))
    }

    @MainActor
    func testCancellationAndQuitWaitForCaptureWithoutPublishingIt() async throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let gate = SignatureWorkspaceGate()
        let owner = AIRSFileOpen(hasModal: { false }, signatureCapture: { unit, id in
            let result = try CodeSignatureEvidenceDocument.capture(unit: unit, componentID: id)
            await gate.wait()
            return result
        })
        let audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        await owner.inventory(app, audit: audit, entitlements: entitlements)?.value
        let component = try XCTUnwrap(owner.inventoryReview?.inventory.components.first)
        let task = try XCTUnwrap(owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements))
        await gate.started()
        owner.cancel()
        XCTAssertTrue(owner.isBusy)
        await gate.release()
        await task.value
        XCTAssertTrue(owner.inventoryReview?.signatureEvidence.isEmpty == true)
        XCTAssertFalse(owner.isBusy)

        let next = try XCTUnwrap(owner.captureSignatureEvidence(component.id, audit: audit, entitlements: entitlements))
        await gate.started()
        let quitting = Task { await owner.finishBeforeQuit() }
        while !owner.isTerminating { await Task.yield() }
        XCTAssertTrue(owner.isBusy)
        await gate.release()
        await next.value
        let finished = await quitting.value
        XCTAssertTrue(finished)
        XCTAssertNil(owner.inventoryReview)
        XCTAssertNil(owner.signatureEvidenceReview)
        XCTAssertFalse(owner.isBusy)
    }

    private func fixture() throws -> URL {
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("AIRS-signature-workspace-\(UUID())/Owned.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("fixtures/generated/before.macho"),
            to: root.appendingPathComponent("Contents/MacOS/Main"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Main", "CFBundleIdentifier": "owned.signature"],
            format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        return root
    }
}

private actor SignatureWorkspaceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func started() async {
        if continuation == nil { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
