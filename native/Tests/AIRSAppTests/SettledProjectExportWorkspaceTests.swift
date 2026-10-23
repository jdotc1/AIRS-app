import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements
@testable import AIRSApp

/// Source-only selectors. Do not execute before separately allocated validation.
final class SettledProjectExportWorkspaceTests:XCTestCase {
    private struct Fixture {
        let root:URL
        let package:URL
        let owner:AIRSFileOpen
        let history:PortableSettledBatchEvidence
        let library:EntitlementBatchHistory
        let project:InspectionProject
    }
    @MainActor
    private func fixture() async throws -> Fixture {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-native-settled-export-20261021-tests", isDirectory: true).path).appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=InspectionProjectStore(root:root.appendingPathComponent("store"))
        var project=try await store.create(name:"Owned native export fixture")
        let row=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/absent/Before.app"),current:URL(fileURLWithPath:"/absent/After.app"),architecture:.arm64),status:.completed,message:"Original completed outcome",changedCount:2,unchangedCount:3,retainedReportID:UUID())
        let cancelled=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/absent/OtherBefore.app"),current:URL(fileURLWithPath:"/absent/OtherAfter.app"),architecture:.arm64),status:.cancelled,message:"Recorded cancellation")
        let record=try EntitlementBatchRecord(result:.init(id:UUID(),rows:[row,cancelled],settled:true,cancelled:true))
        let library=EntitlementBatchHistory(root:root.appendingPathComponent("selected-history"))
        let historyID=try await library.keep(record.data())
        project=try await store.linkBatch(.init(family:.entitlements,historyID:historyID,rowIDs:[row.id,cancelled.id]),to:project.id)
        project=try await store.linkBatch(.init(family:.entitlements,historyID:UUID(),rowIDs:[]),to:project.id)
        project=try await store.linkBatch(.init(family:.audit,historyID:UUID(),rowIDs:[]),to:project.id)
        let history=try PortableSettledBatchEvidence.prepare(project:project,records:[historyID:try record.data()])
        let package=root.appendingPathComponent("project.airsproject")
        try await store.exportPortableProject(project.id,to:package)
        let owner=AIRSFileOpen(hasModal:{false},projectStore:store);owner.projectReview = .init(project:project)
        return .init(root:root,package:package,owner:owner,history:history,library:library,project:project)
    }
    @MainActor
    private func prepare(_ f:Fixture) async {
        await f.owner.prepareSettledProjectExport(package:f.package,purpose:.export,historyReader:{_ in f.history})?.value
    }
    @MainActor
    func testConsentSnapshotExportsExactBytesAndPreservesLiveReports() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let audit=AuditWorkspace(),entitlements=EntitlementsWorkspace(batchHistory:f.library),revision=audit.reportRevision
        let entitlementRevision=entitlements.model.reportRevision
        await f.owner.prepareSettledProjectExport(package:f.package,purpose:.export,historyReader:{@Sendable project in try await entitlements.preparePortableBatchHistory(project)})?.value
        let preview=try XCTUnwrap(f.owner.settledProjectExportPreview)
        XCTAssertEqual(preview.history.outcomes.map(\.absence),[nil,.missing,.unsupportedFamily])
        XCTAssertEqual(preview.history.outcomes[0].rows.map(\.status),[.completed,.cancelled])
        XCTAssertTrue(preview.history.outcomes[0].rows.allSatisfy{!$0.reportIncluded})
        let target=f.root.appendingPathComponent("companion")
        XCTAssertNil(f.owner.writeSettledProjectExport(to:target,confirmed:false,audit:audit,entitlements:entitlements))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        await f.owner.writeSettledProjectExport(to:target,confirmed:true,audit:audit,entitlements:entitlements)?.value
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("settled-batches.json")),f.history.originalBytes)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("project.airsproject/manifest.json")),try Data(contentsOf:f.package.appendingPathComponent("manifest.json")))
        XCTAssertEqual(audit.reportRevision,revision);XCTAssertEqual(entitlements.model.reportRevision,entitlementRevision)
        XCTAssertNil(f.owner.settledProjectExportPreview);XCTAssertFalse(f.owner.hasPortableProjectPreview)
    }
    @MainActor
    func testSettledConsentBlocksProgrammaticProjectChangesAndOrdinaryPreview() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let audit=AuditWorkspace(),entitlements=EntitlementsWorkspace()
        await f.owner.previewPortableProjectPackage(f.package)?.value
        await f.owner.reconstructPortableProject(to:f.root.appendingPathComponent("guard-recipient"),audit:audit,entitlements:entitlements)?.value
        XCTAssertTrue(f.owner.canReturnToOriginalProjectStore)
        await prepare(f)
        let id=f.owner.settledProjectExportPreview?.id
        XCTAssertNil(f.owner.returnToOriginalProjectStore(audit:audit,entitlements:entitlements))
        XCTAssertNil(f.owner.projectOperation("Forbidden",writing:true,audit:audit,entitlements:entitlements){_ in XCTFail("Mutation ran during consent");return nil})
        f.owner.previewPortableProjectExport();XCTAssertNil(f.owner.portableProjectPreview)
        XCTAssertNil(f.owner.previewPortableProjectPackage(f.package))
        XCTAssertNil(f.owner.importProjectEvidence(f.root.appendingPathComponent("missing"),audit:audit,entitlements:entitlements))
        XCTAssertEqual(f.owner.settledProjectExportPreview?.id,id)
        f.owner.cancelSettledProjectExport();XCTAssertFalse(f.owner.hasPortableProjectPreview)
        f.owner.previewPortableProjectExport();XCTAssertNotNil(f.owner.portableProjectPreview)
    }
    @MainActor
    func testRecipientReexportPreservesOriginalDetachedHistoryWithoutLibraryFallback() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let companion=f.root.appendingPathComponent("companion")
        try PortableSettledBatchProject.write(PortableProjectReader.prepare(at:f.package),history:f.history,to:companion)
        let recipient=try await PortableSettledBatchProject.reconstruct(PortableSettledBatchProject.prepare(at:companion),to:f.root.appendingPathComponent("recipient"))
        let owner=AIRSFileOpen(hasModal:{false},projectStore:recipient);owner.projectReview = .init(project:f.project)
        await owner.prepareSettledProjectExport(package:f.package,purpose:.reexport,historyReader:{_ in XCTFail("Recipient must not consult live history");throw CancellationError()})?.value
        XCTAssertNotNil(owner.settledProjectExportPreview)
        let target=f.root.appendingPathComponent("reexport")
        await owner.writeSettledProjectExport(to:target,confirmed:true,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace())?.value
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("settled-batches.json")),f.history.originalBytes)
        XCTAssertEqual(owner.projectStore.storageRoot.standardizedFileURL.path,recipient.storageRoot.standardizedFileURL.path)
    }
    @MainActor
    func testForeignRevisionAndByteDifferentWitnessesDeclineBeforeConsent() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.owner.projectReview = .init(project:InspectionProject(name:"Foreign"));await prepare(f)
        XCTAssertNil(f.owner.settledProjectExportPreview)
        var newer=f.project;newer.revision += 1
        f.owner.projectReview = .init(project:newer);await prepare(f)
        XCTAssertNil(f.owner.settledProjectExportPreview)
        f.owner.projectReview = .init(project:f.project)
        let manifest=f.owner.projectStore.storageRoot.appendingPathComponent("Projects/\(f.project.id.uuidString)/manifest.json")
        let original=try Data(contentsOf:manifest);try (Data(" \n".utf8)+original).write(to:manifest,options:.atomic)
        await prepare(f);XCTAssertNil(f.owner.settledProjectExportPreview)
        XCTAssertFalse(f.owner.isBusy)
    }
    @MainActor
    func testCancellationAndChangedSessionPreventLateConsent() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let cancelled=try XCTUnwrap(f.owner.prepareSettledProjectExport(package:f.package,purpose:.export,historyReader:{_ in f.history}))
        f.owner.cancelSettledProjectExport();await cancelled.value
        XCTAssertNil(f.owner.settledProjectExportPreview)
        let changed=try XCTUnwrap(f.owner.prepareSettledProjectExport(package:f.package,purpose:.export,historyReader:{_ in f.history}))
        f.owner.projectReview = .init(project:f.project);await changed.value
        XCTAssertNil(f.owner.settledProjectExportPreview)
    }
    @MainActor
    func testChangedStoreOrPackageAfterConsentCannotPublish() async throws {
        for changeStore in [false,true] {
            let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            await prepare(f);XCTAssertNotNil(f.owner.settledProjectExportPreview)
            if changeStore {_=try await f.owner.projectStore.addAnnotation("External revision",acknowledged:false,to:f.project.id)}
            else {try Data("{}".utf8).write(to:f.package.appendingPathComponent("manifest.json"),options:.atomic)}
            let target=f.root.appendingPathComponent("refused")
            await f.owner.writeSettledProjectExport(to:target,confirmed:true,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace())?.value
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
            XCTAssertNotNil(f.owner.settledProjectExportPreview)
        }
    }
    @MainActor
    func testProtectedAndExistingDestinationsPreserveSourceAndConsent() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        await prepare(f)
        let existing=f.root.appendingPathComponent("existing");try FileManager.default.createDirectory(at:existing,withIntermediateDirectories:false)
        let marker=existing.appendingPathComponent("marker");try Data("preserve".utf8).write(to:marker)
        for target in [f.owner.projectStore.storageRoot.appendingPathComponent("child"),f.package.appendingPathComponent("child"),existing] {
            await f.owner.writeSettledProjectExport(to:target,confirmed:true,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace())?.value
            XCTAssertNotNil(f.owner.settledProjectExportPreview)
        }
        XCTAssertEqual(try String(contentsOf:marker,encoding:.utf8),"preserve")
        f.owner.closeProjects();XCTAssertNil(f.owner.settledProjectExportPreview)
    }
    @MainActor
    func testCompanionImportDeclinesDuringExportConsentAndResumesAfterCancel() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let companion=f.root.appendingPathComponent("import-companion")
        try PortableSettledBatchProject.write(PortableProjectReader.prepare(at:f.package),history:f.history,to:companion)
        await prepare(f)
        let preview=try XCTUnwrap(f.owner.settledProjectExportPreview)
        let session=f.owner.projectReview?.id
        let store=f.owner.projectStore.storageRoot.standardizedFileURL.path
        XCTAssertNil(f.owner.previewSettledProjectPackage(companion))
        XCTAssertEqual(f.owner.settledProjectExportPreview?.id,preview.id)
        XCTAssertNil(f.owner.portableProjectPreview)
        XCTAssertNil(f.owner.importedProjectHistory)
        XCTAssertEqual(f.owner.projectReview?.id,session)
        XCTAssertEqual(f.owner.projectStore.storageRoot.standardizedFileURL.path,store)
        XCTAssertFalse(f.owner.isBusy)
        f.owner.cancelSettledProjectExport()
        let task=try XCTUnwrap(f.owner.previewSettledProjectPackage(companion))
        await task.value
        XCTAssertNil(f.owner.settledProjectExportPreview)
        XCTAssertNotNil(f.owner.portableProjectPreview?.settledAdmission)
        XCTAssertEqual(f.owner.portableProjectPreview?.project.id,f.project.id)
        XCTAssertEqual(f.owner.projectReview?.id,session)
        XCTAssertEqual(f.owner.projectStore.storageRoot.standardizedFileURL.path,store)
    }
    @MainActor
    func testQuitSettlesExportWriteAndFailureRetainsConsent() async throws {
        for fail in [false,true] {
            let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            let gate=SettledExportGate()
            let owner=AIRSFileOpen(hasModal:{false},projectStore:f.owner.projectStore,settledExportWrite:{preview,target in
                try await gate.wait();try preview.write(to:target)
            });owner.projectReview = .init(project:f.project)
            await owner.prepareSettledProjectExport(package:f.package,purpose:.export,historyReader:{_ in f.history})?.value
            let target=f.root.appendingPathComponent("quit-write")
            let write=try XCTUnwrap(owner.writeSettledProjectExport(to:target,confirmed:true,audit:AuditWorkspace(),entitlements:EntitlementsWorkspace()))
            await gate.started();XCTAssertFalse(owner.canCancel)
            let quitting=Task {await owner.finishBeforeQuit()}
            while !owner.isTerminating {await Task.yield()}
            owner.cancel();await gate.finish(fail:fail);await write.value
            let result=await quitting.value;XCTAssertEqual(result,!fail)
            XCTAssertEqual(FileManager.default.fileExists(atPath:target.path),!fail)
            XCTAssertEqual(owner.settledProjectExportPreview != nil,fail)
        }
    }
}
private actor SettledExportGate {
    private var continuation:CheckedContinuation<Void,Error>?
    private var observer:CheckedContinuation<Void,Never>?
    func wait() async throws {try await withCheckedThrowingContinuation {continuation=$0;observer?.resume();observer=nil}}
    func started() async {if continuation == nil {await withCheckedContinuation{observer=$0}}}
    func finish(fail:Bool) {if fail {continuation?.resume(throwing:CocoaError(.fileWriteUnknown))}else{continuation?.resume()};continuation=nil}
}
