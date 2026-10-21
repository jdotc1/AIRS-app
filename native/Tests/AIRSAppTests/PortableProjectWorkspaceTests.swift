import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp

final class PortableProjectWorkspaceTests: XCTestCase {
    @MainActor
    func fixture() async throws -> (URL,AIRSFileOpen,AuditWorkspace,EntitlementsWorkspace,InspectionProject) {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=InspectionProjectStore(root:root.appendingPathComponent("source"))
        var project=try await store.create(name:"Synthetic C5 interface")
        let bytes=try ComponentInventoryDocumentCodec.archive(.init(scope:.init(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[]),components:[]))
        project=try await store.addEvidence(bytes,to:project.id)
        project=try await store.pinBaseline(project.evidence[0].id,in:project.id)
        project=try await store.addAnnotation("Synthetic review note",acknowledged:true,to:project.id)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        owner.projectReview = .init(project:project)
        return (root,owner,audit,entitlements,project)
    }
    @MainActor
    func testPreviewExportAndReconstructionPreserveWorkspacesAndReturnToSource() async throws {
        let (root,owner,audit,entitlements,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        let revision=audit.reportRevision,entitlementRevision=entitlements.model.reportRevision
        owner.previewPortableProjectExport()
        let preview=try XCTUnwrap(owner.portableProjectPreview)
        XCTAssertEqual(preview.project.annotationIDs,project.annotationIDs)
        let package=root.appendingPathComponent("review.airsproject")
        XCTAssertNil(owner.exportPortableProject(to:package,confirmed:false,audit:audit,entitlements:entitlements))
        XCTAssertFalse(FileManager.default.fileExists(atPath:package.path))
        await owner.exportPortableProject(to:package,confirmed:true,audit:audit,entitlements:entitlements)?.value
        XCTAssertNil(owner.portableProjectPreview)
        await owner.previewPortableProjectPackage(package)?.value
        XCTAssertEqual(owner.portableProjectPreview?.project.id,project.id)
        let recipient=root.appendingPathComponent("recipient")
        await owner.reconstructPortableProject(to:recipient,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(owner.projectStore.storageRoot,recipient)
        XCTAssertEqual(owner.projectReview?.project?.pinnedBaselineID,project.pinnedBaselineID)
        XCTAssertTrue(owner.canReturnToOriginalProjectStore)
        XCTAssertEqual(audit.reportRevision,revision);XCTAssertEqual(entitlements.model.reportRevision,entitlementRevision)
        XCTAssertTrue(entitlements.protectedInputs.contains(recipient))
        await owner.returnToOriginalProjectStore(audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(owner.projectStore.storageRoot.path,root.appendingPathComponent("source").path)
        XCTAssertEqual(owner.projectReview?.project?.id,project.id)
        XCTAssertFalse(owner.canReturnToOriginalProjectStore)
    }
    @MainActor
    func testStaleProjectAndChangedPackageDeclineWithoutNewDestination() async throws {
        let (root,owner,audit,entitlements,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        owner.previewPortableProjectExport()
        _=try await owner.projectStore.addAnnotation("External revision",acknowledged:false,to:project.id)
        let output=root.appendingPathComponent("stale.airsproject")
        await owner.exportPortableProject(to:output,confirmed:true,audit:audit,entitlements:entitlements)?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path));XCTAssertNotNil(owner.portableProjectPreview)
        owner.cancelPortableProjectPreview()
        let valid=root.appendingPathComponent("valid.airsproject")
        try await owner.projectStore.exportPortableProject(project.id,to:valid)
        await owner.previewPortableProjectPackage(valid)?.value
        try Data("{}".utf8).write(to:valid.appendingPathComponent("manifest.json"),options:.atomic)
        let recipient=root.appendingPathComponent("recipient")
        await owner.reconstructPortableProject(to:recipient,audit:audit,entitlements:entitlements)?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:recipient.path))
        XCTAssertEqual(owner.projectStore.storageRoot.path,root.appendingPathComponent("source").path)
    }
    @MainActor
    func testCancelInvalidPackageAndProtectedExportKeepCurrentProject() async throws {
        let (root,owner,audit,entitlements,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        owner.previewPortableProjectExport();owner.cancelPortableProjectPreview();XCTAssertNil(owner.portableProjectPreview)
        await owner.previewPortableProjectPackage(root.appendingPathComponent("missing"))?.value
        XCTAssertNil(owner.portableProjectPreview);XCTAssertEqual(owner.projectReview?.project?.id,project.id)
        owner.previewPortableProjectExport()
        await owner.exportPortableProject(to:owner.projectStore.storageRoot.appendingPathComponent("unsafe.airsproject"),confirmed:true,audit:audit,entitlements:entitlements)?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath:owner.projectStore.storageRoot.appendingPathComponent("unsafe.airsproject").path))
        owner.closeProjects();XCTAssertNil(owner.portableProjectPreview);XCTAssertFalse(owner.isBusy)
    }
    @MainActor
    func testPreviewOwnsProjectSession() async throws {
        let (root,owner,audit,entitlements,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
        owner.previewPortableProjectExport()
        let preview=try XCTUnwrap(owner.portableProjectPreview)
        owner.previewPortableProjectExport()
        XCTAssertEqual(owner.portableProjectPreview?.id,preview.id)
        owner.reviewProjectEvidence(project.evidence[0].id,audit:audit,entitlements:entitlements)
        XCTAssertNotNil(owner.projectReview);XCTAssertNil(owner.archiveReview);XCTAssertFalse(owner.isBusy)
        XCTAssertNil(owner.importProjectEvidence(root.appendingPathComponent("missing"),audit:audit,entitlements:entitlements))
        XCTAssertNil(owner.exportProjectEvidence(nil,to:root.appendingPathComponent("metadata.json"),audit:audit,entitlements:entitlements))
        let settled=await owner.finishBeforeQuit();XCTAssertTrue(settled)
        XCTAssertNil(owner.portableProjectPreview)
    }

    @MainActor
    func testPortableWritesSettleBeforeQuitAndFailureKeepsPreview() async throws {
        for fail in [false,true] {
            let (root,source,audit,entitlements,project)=try await fixture();defer {try? FileManager.default.removeItem(at:root)}
            let gate=PortableWriteGate()
            let owner=AIRSFileOpen(hasModal:{false},projectStore:source.projectStore,portableExport:{store,id,revision,url in
                try await gate.write()
                try await store.exportPortableProject(id,to:url,expectedRevision:revision)
            })
            owner.projectReview = .init(project:project);owner.previewPortableProjectExport()
            let output=root.appendingPathComponent("settled.airsproject")
            let writing=try XCTUnwrap(owner.exportPortableProject(to:output,confirmed:true,audit:audit,entitlements:entitlements))
            await gate.started();XCTAssertFalse(owner.canCancel)
            let quitting=Task {await owner.finishBeforeQuit()}
            while !owner.isTerminating {await Task.yield()}
            owner.cancel();await gate.finish(fail:fail);await writing.value
            let quit=await quitting.value;XCTAssertEqual(quit,!fail)
            XCTAssertEqual(FileManager.default.fileExists(atPath:output.path),!fail)
            XCTAssertEqual(owner.portableProjectPreview != nil,fail)
            if fail {XCTAssertNotNil(owner.projectReview);owner.resumeAfterCancelledQuit();owner.closeProjects();XCTAssertFalse(owner.blocksActions)}
        }
    }

}

private actor PortableWriteGate {
    var continuation:CheckedContinuation<Void,Error>?
    var waiter:CheckedContinuation<Void,Never>?
    func write() async throws {try await withCheckedThrowingContinuation {continuation=$0;waiter?.resume();waiter=nil}}
    func started() async {if continuation == nil {await withCheckedContinuation {waiter=$0}}}
    func finish(fail:Bool) {
        if fail {continuation?.resume(throwing:CocoaError(.fileWriteNoPermission))} else {continuation?.resume()}
        continuation=nil
    }
}
