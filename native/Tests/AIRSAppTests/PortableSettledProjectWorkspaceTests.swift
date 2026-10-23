import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements
@testable import AIRSApp

final class PortableSettledProjectWorkspaceTests:XCTestCase {
    @MainActor
    private func fixture() async throws -> (URL,AIRSFileOpen,URL,InspectionProject) {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-native-settled-project-import-20261021-tests", isDirectory: true).path)
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=InspectionProjectStore(root:root.appendingPathComponent("source"))
        var project=try await store.create(name:"Synthetic imported historical outcomes")
        let completed=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/missing/Before.app"),current:URL(fileURLWithPath:"/missing/After.app"),architecture:.arm64),status:.completed,message:"Recorded comparison",changedCount:2,unchangedCount:3,retainedReportID:UUID())
        let cancelled=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/missing/OtherBefore.app"),current:URL(fileURLWithPath:"/missing/OtherAfter.app"),architecture:.arm64),status:.cancelled,message:"Recorded cancellation")
        let historyID=UUID()
        let record=try EntitlementBatchRecord(result:.init(id:UUID(),rows:[completed,cancelled],settled:true,cancelled:true))
        project=try await store.linkBatch(.init(family:.entitlements,historyID:historyID,rowIDs:[completed.id,cancelled.id]),to:project.id)
        project=try await store.linkBatch(.init(family:.entitlements,historyID:UUID(),rowIDs:[]),to:project.id)
        project=try await store.linkBatch(.init(family:.audit,historyID:UUID(),rowIDs:[]),to:project.id)
        let package=root.appendingPathComponent("original.airsproject")
        try await store.exportPortableProject(project.id,to:package)
        let admission=try PortableProjectReader.prepare(at:package)
        let history=try PortableSettledBatchEvidence.prepare(project:project,records:[historyID:try record.data()])
        let companion=root.appendingPathComponent("companion")
        try PortableSettledBatchProject.write(admission,history:history,to:companion)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store)
        owner.projectReview = .init(project:project)
        return (root,owner,companion,project)
    }
    @MainActor
    func testCompanionPreviewRetainsAdmissionAndExplicitAbsences() async throws {
        let (root,owner,companion,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        await owner.previewSettledProjectPackage(companion)?.value
        let preview=try XCTUnwrap(owner.portableProjectPreview)
        XCTAssertEqual(preview.sourceURL,companion)
        XCTAssertEqual(preview.project.id,project.id)
        XCTAssertEqual(preview.settledAdmission?.history.outcomes.map(\.absence),[nil,.missing,.unsupportedFamily])
        let outcome=try XCTUnwrap(preview.settledAdmission?.history.outcomes.first)
        XCTAssertEqual(outcome.cancelled,true)
        XCTAssertEqual(outcome.rows.map(\.status),[.completed,.cancelled])
        XCTAssertEqual(outcome.rows.first?.changedCount,2)
        XCTAssertEqual(outcome.rows.first?.unchangedCount,3)
        XCTAssertTrue(outcome.rows.allSatisfy {!$0.reportIncluded})
        XCTAssertNil(owner.importedProjectHistory)
        XCTAssertEqual(owner.projectStore.storageRoot.standardizedFileURL.path,root.appendingPathComponent("source").standardizedFileURL.path)
    }
    @MainActor
    func testCompanionReconstructsAndReturnsWithoutChangingLiveReports() async throws {
        let (root,owner,companion,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        let auditRevision=audit.reportRevision,entitlementRevision=entitlements.model.reportRevision
        await owner.previewSettledProjectPackage(companion)?.value
        let bytes=try XCTUnwrap(owner.portableProjectPreview?.settledAdmission?.history.originalBytes)
        let recipient=root.appendingPathComponent("recipient")
        await owner.reconstructPortableProject(to:recipient,audit:audit,entitlements:entitlements)?.value
        let snapshot=try XCTUnwrap(owner.importedProjectHistory)
        XCTAssertTrue(snapshot.matches(project:owner.projectReview?.project,store:owner.projectStore.storageRoot))
        XCTAssertEqual(snapshot.history.originalBytes,bytes)
        XCTAssertEqual(owner.projectReview?.project?.id,project.id)
        XCTAssertEqual(audit.reportRevision,auditRevision)
        XCTAssertEqual(entitlements.model.reportRevision,entitlementRevision)
        await owner.returnToOriginalProjectStore(audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(owner.projectStore.storageRoot.standardizedFileURL.path,root.appendingPathComponent("source").standardizedFileURL.path)
        XCTAssertNil(owner.importedProjectHistory)
        XCTAssertFalse(owner.canReturnToOriginalProjectStore)
        XCTAssertTrue(FileManager.default.fileExists(atPath:recipient.path))
    }
    @MainActor
    func testInvalidCompanionPreservesOriginalSession() async throws {
        let (root,owner,_,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let session=owner.projectReview?.id
        await owner.previewSettledProjectPackage(root.appendingPathComponent("missing"))?.value
        XCTAssertNil(owner.portableProjectPreview)
        XCTAssertEqual(owner.projectReview?.id,session)
        XCTAssertEqual(owner.projectReview?.project?.id,project.id)
        XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testChangedCompanionAfterPreviewCannotPublishStore() async throws {
        let (root,owner,companion,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        await owner.previewSettledProjectPackage(companion)?.value
        try Data("{}".utf8).write(to:companion.appendingPathComponent("settled-batches.json"),options:.atomic)
        let recipient=root.appendingPathComponent("recipient")
        await owner.reconstructPortableProject(to:recipient,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace())?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:recipient.path))
        XCTAssertEqual(owner.projectStore.storageRoot.standardizedFileURL.path,root.appendingPathComponent("source").standardizedFileURL.path)
        XCTAssertNil(owner.importedProjectHistory)
        XCTAssertNotNil(owner.portableProjectPreview)
    }
    @MainActor
    func testExistingDestinationIsPreserved() async throws {
        let (root,owner,companion,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        await owner.previewSettledProjectPackage(companion)?.value
        let recipient=root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at:recipient,withIntermediateDirectories:false)
        let marker=recipient.appendingPathComponent("marker")
        try Data("preserve".utf8).write(to:marker)
        await owner.reconstructPortableProject(to:recipient,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace())?.value
        XCTAssertEqual(try String(contentsOf:marker,encoding:.utf8),"preserve")
        XCTAssertFalse(owner.canReturnToOriginalProjectStore)
        XCTAssertNil(owner.importedProjectHistory)
    }
    @MainActor
    func testCancelledPreviewCannotArriveLate() async throws {
        let (root,owner,companion,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let task=try XCTUnwrap(owner.previewSettledProjectPackage(companion))
        owner.cancelPortableProjectPreview()
        await task.value
        XCTAssertNil(owner.portableProjectPreview)
        XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testChangedSessionCannotReceivePreviewOrReconstruct() async throws {
        let (root,owner,companion,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let task=try XCTUnwrap(owner.previewSettledProjectPackage(companion))
        owner.projectReview = .init(project:project)
        await task.value
        XCTAssertNil(owner.portableProjectPreview)
        await owner.previewSettledProjectPackage(companion)?.value
        owner.projectReview = .init(project:project)
        XCTAssertNil(owner.reconstructPortableProject(to:root.appendingPathComponent("recipient"),audit:AuditWorkspace(),entitlements:EntitlementsWorkspace()))
        XCTAssertNil(owner.importedProjectHistory)
    }
    @MainActor
    func testQuitDuringCompanionPreviewSuppressesLatePresentation() async throws {
        let (root,owner,companion,_)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let task=try XCTUnwrap(owner.previewSettledProjectPackage(companion))
        let settled=await owner.finishBeforeQuit()
        await task.value
        XCTAssertTrue(settled)
        XCTAssertNil(owner.portableProjectPreview)
        XCTAssertNil(owner.importedProjectHistory)
        XCTAssertEqual(owner.projectStore.storageRoot.standardizedFileURL.path,root.appendingPathComponent("source").standardizedFileURL.path)
    }
    @MainActor
    func testQuitSettlesCompanionWriteWithoutSwitchingOriginalContext() async throws {
        let (root,source,companion,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let gate=SettledImportWriteGate()
        let owner=AIRSFileOpen(hasModal:{false},projectStore:source.projectStore,portableSettledReconstruct:{admission,url in
            await gate.wait()
            return try await PortableSettledBatchProject.reconstruct(admission,to:url)
        })
        owner.projectReview = .init(project:project)
        await owner.previewSettledProjectPackage(companion)?.value
        let recipient=root.appendingPathComponent("recipient")
        let task=try XCTUnwrap(owner.reconstructPortableProject(to:recipient,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace()))
        await gate.started()
        XCTAssertFalse(owner.canCancel)
        let quitting=Task {await owner.finishBeforeQuit()}
        while !owner.isTerminating {await Task.yield()}
        await gate.finish()
        await task.value
        let settled=await quitting.value
        XCTAssertTrue(settled)
        XCTAssertTrue(FileManager.default.fileExists(atPath:recipient.path))
        XCTAssertEqual(owner.projectStore.storageRoot,source.projectStore.storageRoot)
        XCTAssertNil(owner.importedProjectHistory)
        XCTAssertFalse(owner.canReturnToOriginalProjectStore)
    }
    @MainActor
    func testHistoricalSnapshotRejectsProjectRevisionAndStoreMismatch() async throws {
        let (root,owner,companion,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        await owner.previewSettledProjectPackage(companion)?.value
        let history=try XCTUnwrap(owner.portableProjectPreview?.settledAdmission?.history)
        let snapshot=ImportedProjectHistorySnapshot(projectID:project.id,revision:project.revision,storeRoot:owner.projectStore.storageRoot,history:history)
        XCTAssertTrue(snapshot.matches(project:project,store:owner.projectStore.storageRoot))
        XCTAssertFalse(snapshot.matches(project:nil,store:owner.projectStore.storageRoot))
        XCTAssertFalse(snapshot.matches(project:InspectionProject(name:"Other"),store:owner.projectStore.storageRoot))
        XCTAssertFalse(snapshot.matches(project:project,store:root.appendingPathComponent("other")))
        let changed=try await owner.projectStore.addAnnotation("Changed",acknowledged:false,to:project.id)
        XCTAssertFalse(snapshot.matches(project:changed,store:owner.projectStore.storageRoot))
    }
}

private actor SettledImportWriteGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var observer:CheckedContinuation<Void,Never>?
    func wait() async {await withCheckedContinuation {continuation=$0;observer?.resume();observer=nil}}
    func started() async {if continuation == nil {await withCheckedContinuation {observer=$0}}}
    func finish() {continuation?.resume();continuation=nil}
}
