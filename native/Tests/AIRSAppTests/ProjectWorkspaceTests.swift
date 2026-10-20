import XCTest
import AIRSCore
import AIRSEntitlements
@testable import AIRSApp
final class ProjectWorkspaceTests:XCTestCase {
    @MainActor
    func testProjectImportPinProtectedExportAndHistoricalReviewPreserveWorkspaces() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root.appendingPathComponent("Store")),project=try await store.create(name:"Owned")
        let raw=try ComponentInventoryDocumentCodec.encode(.init(scope:.init(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[]),components:[]))
        let source=root.appendingPathComponent("source.json");try raw.write(to:source)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        owner.configureProjectProtection(audit:audit,entitlements:entitlements)
        owner.projectReview = .init(entries:[],project:project)
        let revision=audit.reportRevision
        await owner.importProjectEvidence(source,audit:audit,entitlements:entitlements)?.value
        let retained=try XCTUnwrap(owner.projectReview?.project?.evidence.first)
        XCTAssertEqual(audit.reportRevision,revision)
        let manifestURL=store.storageRoot.appendingPathComponent("Projects/\(project.id.uuidString)/manifest.json")
        XCTAssertThrowsError(try audit.validateExportDestination(manifestURL,protectedInputs:[]))
        XCTAssertTrue(entitlements.protectedInputs.contains(store.storageRoot))
        let before=try Data(contentsOf:manifestURL)
        await owner.exportProjectEvidence(retained.id,to:manifestURL,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(try Data(contentsOf:manifestURL),before)
        await owner.exportProjectEvidence(retained.id,to:source,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(try Data(contentsOf:source),raw)
        let output=root.appendingPathComponent("export.airsreview")
        await owner.exportProjectEvidence(retained.id,to:output,audit:audit,entitlements:entitlements)?.value
        let expected=try await store.evidence(retained.id)
        XCTAssertEqual(try Data(contentsOf:output),expected)
        owner.reviewProjectEvidence(retained.id,audit:audit,entitlements:entitlements)
        // Wait through the owner's exposed cancellable job using quit settlement,
        // which must not publish into a terminating workspace.
        _=await owner.finishBeforeQuit()
        XCTAssertEqual(audit.reportRevision,revision)
        XCTAssertNil(owner.assessmentReview)
    }
    func testRawImportWrapperIsStableAndRetainsOriginalBytes() throws {
        let raw=try ComponentInventoryDocumentCodec.encode(.init(scope:.init(searchedLocations:[],completion:.partial,exclusions:[],issues:["Owned gap"]),components:[]))
        let first=try AIRSFileOpen.projectArchive(raw),second=try AIRSFileOpen.projectArchive(raw)
        XCTAssertEqual(first,second)
        let archive=try InspectionArchive.decode(first)
        XCTAssertEqual(archive.attachments.first?.bytes,raw)
    }
    @MainActor
    func testBatchAssociationProjectsMetadataDoesNotChangeSettledBatchFiles() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root.appendingPathComponent("Store")),project=try await store.create(name:"Owned")
        let batch=UUID(),file=root.appendingPathComponent("settled-owned.json"),bytes=Data("owned settled outcomes".utf8)
        try bytes.write(to:file)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        owner.projectReview = .init(project:project)
        await owner.projectOperation("Link",writing:true,audit:audit,entitlements:entitlements) {try await $0.linkBatch(.init(family:.audit,historyID:batch,rowIDs:[]),to:project.id).id}?.value
        XCTAssertEqual(audit.projectHistoryIDs[batch],[project.id])
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertNil(audit.batchSnapshot)
    }
    @MainActor
    func testUnavailableRememberedProjectKeepsOtherProjectsAndRecoveryVisible() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),bad=try await store.create(name:"Unavailable"),good=try await store.create(name:"Available")
        let manifest=root.appendingPathComponent("Projects/\(bad.id.uuidString)/manifest.json")
        try Data("corrupt".utf8).write(to:manifest)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        owner.projectReview = .init()
        await owner.projectOperation("Reopen remembered",writing:false,audit:audit,entitlements:entitlements) {_ in bad.id}?.value
        XCTAssertEqual(owner.projectReview?.entries.count,2)
        XCTAssertNotNil(owner.projectReview?.entries.first{$0.id == bad.id}?.issue)
        XCTAssertEqual(owner.projectReview?.project?.id,good.id)
        try FileManager.default.removeItem(at:manifest.deletingLastPathComponent())
        await owner.projectOperation("Deleted remembered",writing:false,audit:audit,entitlements:entitlements) {_ in bad.id}?.value
        XCTAssertEqual(owner.projectReview?.entries.count,1)
        XCTAssertEqual(owner.projectReview?.project?.id,good.id)
    }
    @MainActor
    func testProjectExportFailureDuringQuitRetainsProjectAndRefusesQuit() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root.appendingPathComponent("Store")),project=try await store.create(name:"Owned")
        let gate=ProjectWriteGate(),audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        let owner=AIRSFileOpen(hasModal:{false},inventoryWrite:{_,_ in try await gate.write()},projectStore:store)
        owner.projectReview = .init(project:project)
        let writing=try XCTUnwrap(owner.exportProjectEvidence(nil,to:root.appendingPathComponent("metadata.json"),audit:audit,entitlements:entitlements))
        await gate.started()
        let quitting=Task {await owner.finishBeforeQuit()}
        while !owner.isTerminating {await Task.yield()}
        owner.cancel();await gate.fail();await writing.value
        let quit=await quitting.value
        XCTAssertFalse(quit);XCTAssertNotNil(owner.projectReview)
        owner.resumeAfterCancelledQuit();owner.closeProjects()
        XCTAssertFalse(owner.blocksActions)
    }
    private func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-projects-20261020/workspace-tests/\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
}

private actor ProjectWriteGate {
    var continuation:CheckedContinuation<Void,Error>?
    var waiter:CheckedContinuation<Void,Never>?
    func write() async throws {try await withCheckedThrowingContinuation {continuation=$0;waiter?.resume();waiter=nil}}
    func started() async {if continuation == nil {await withCheckedContinuation {waiter=$0}}}
    func fail() {continuation?.resume(throwing:CocoaError(.fileWriteNoPermission));continuation=nil}
}
