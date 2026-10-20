import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements
final class InspectionProjectStoreTests:XCTestCase {
    func testDuplicateImportPinAndNotesPreserveOriginalBytesAcrossRelaunch() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),bytes=try evidence()
        let project=try await store.create(name:"Owned project")
        let added=try await store.addEvidence(bytes,to:project.id)
        let duplicate=try await store.addEvidence(bytes,to:project.id)
        XCTAssertEqual(duplicate.revision,added.revision)
        let id=try XCTUnwrap(added.evidence.first?.id)
        _=try await store.pinBaseline(id,in:project.id)
        let noted=try await store.addAnnotation("Reviewed; declarations only",acknowledged:true,to:project.id)
        let relaunched=InspectionProjectStore(root:root)
        let restored=try await relaunched.load(project.id)
        XCTAssertEqual(restored.pinnedBaselineID,id)
        XCTAssertEqual(restored.annotationIDs,noted.annotationIDs)
        let retained=try await relaunched.evidence(id)
        XCTAssertEqual(retained,bytes)
        let notes=try await relaunched.annotations(in:project.id)
        XCTAssertEqual(notes.first?.text,"Reviewed; declarations only")
    }
    func testStaleWriterAndInterruptedManifestPreservePreviousRevision() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root)
        var first=try await store.create(name:"Before")
        first.name="After";first.revision += 1
        try await store.save(first,expectedRevision:1)
        do {try await store.save(first,expectedRevision:1);XCTFail("Stale write")} catch {}
        let failing=InspectionProjectStore(root:root,publish:{_,_ in throw CocoaError(.fileWriteUnknown)})
        var next=try await store.metadata(first.id);next.name="Interrupted";next.revision += 1
        do {try await failing.save(next,expectedRevision:2);XCTFail("Interrupted write")} catch {XCTAssertEqual((error as NSError).code,CocoaError.fileWriteUnknown.rawValue)}
        let restored=try await store.load(first.id)
        XCTAssertEqual(restored.name,"After");XCTAssertEqual(restored.revision,2)
    }
    func testMissingCorruptAndDeletedPinnedEvidenceDoNotBecomeValidBaselines() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),project=try await store.create(name:"Owned")
        let added=try await store.addEvidence(evidence(),to:project.id),id=try XCTUnwrap(added.evidence.first?.id)
        _=try await store.pinBaseline(id,in:project.id)
        do {try await store.removeEvidence(id,from:project.id);XCTFail("Pinned removal")} catch {}
        let path=root.appendingPathComponent("Evidence/\(id.uuidString)/report.json")
        try Data("corrupt".utf8).write(to:path)
        do {_=try await store.load(project.id);XCTFail("Corrupt bytes")} catch {}
        try FileManager.default.removeItem(at:path)
        do {_=try await store.load(project.id);XCTFail("Missing pinned bytes")} catch {}
        _=try await store.pinBaseline(nil,in:project.id)
        try await store.removeEvidence(id,from:project.id)
        let repaired=try await store.load(project.id)
        XCTAssertTrue(repaired.evidence.isEmpty)
    }
    func testCapacityRefusesRatherThanEvictsAndBatchLinksAreMetadataOnly() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root,maximumProjects:1)
        let project=try await store.create(name:"Only")
        do {_=try await store.create(name:"Overflow");XCTFail("Capacity")} catch {}
        let batchID=UUID()
        let linked=try await store.linkBatch(.init(family:.audit,historyID:batchID,rowIDs:[UUID()]),to:project.id)
        XCTAssertEqual(linked.batchLinks.first?.historyID,batchID)
        XCTAssertEqual(linked.id,project.id)
        XCTAssertTrue(linked.evidence.isEmpty)
    }
    func testAnnotationCorrectionIsAppendOnlyAndObservationFileIsUnchanged() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),project=try await store.create(name:"Owned")
        let added=try await store.addEvidence(evidence(),to:project.id),id=try XCTUnwrap(added.evidence.first?.id)
        let file=root.appendingPathComponent("Evidence/\(id.uuidString)/report.json"),before=try Data(contentsOf:root.appendingPathComponent("Evidence/\(id.uuidString)/report.json"))
        let first=try await store.addAnnotation("Initial",acknowledged:false,to:project.id),note=try XCTUnwrap(first.annotationIDs.first)
        let updated=try await store.addAnnotation("Corrected review note",acknowledged:true,to:project.id,supersedes:note)
        XCTAssertEqual(updated.annotations.count,2)
        XCTAssertEqual(updated.annotations[0].text,"Initial")
        XCTAssertEqual(updated.annotations[1].supersedes,note)
        XCTAssertEqual(try Data(contentsOf:file),before)
        var rewrite=updated;rewrite.revision += 1;rewrite.annotations=[];rewrite.annotationIDs=[]
        do {try await store.save(rewrite,expectedRevision:updated.revision);XCTFail("Cannot erase previous review notes")} catch {}
    }
    func testReferencesAcrossProjectsPreventPurgeAndCapacityKeepsUnreferencedCopy() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root,maximumEvidence:1),a=try await store.create(name:"A"),b=try await store.create(name:"B"),bytes=try evidence()
        let first=try await store.addEvidence(bytes,to:a.id),id=try XCTUnwrap(first.evidence.first?.id)
        _=try await store.addEvidence(bytes,to:b.id)
        try await store.removeEvidence(id,from:a.id)
        do {try await store.removeRetainedEvidence(id);XCTFail("Other project still references it")} catch {}
        try await store.removeEvidence(id,from:b.id)
        do {_=try await store.addEvidence(evidence(),to:a.id);XCTFail("Unreferenced copy still occupies capacity")} catch {}
        let retained=try await store.evidence(id)
        XCTAssertEqual(retained,bytes)
        let unused=try await store.unreferencedEvidence()
        XCTAssertEqual(unused,[id])
    }
    func testSeparateStoreStaleWriterCannotOverwriteCommittedSuccessor() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let first=InspectionProjectStore(root:root),second=InspectionProjectStore(root:root)
        let project=try await first.create(name:"Before")
        var a=try await first.load(project.id),b=try await second.load(project.id)
        a.name="Committed";a.revision += 1;b.name="Stale";b.revision += 1
        try await first.save(a,expectedRevision:1)
        do {try await second.save(b,expectedRevision:1);XCTFail("Stale second writer")} catch {}
        let loaded=try await second.load(project.id)
        XCTAssertEqual(loaded.name,"Committed");XCTAssertEqual(loaded.revision,2)
    }
    func testCaptureTimeExtractorAndAppVersionLabelsRemainSeparate() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),project=try await store.create(name:"Timeline")
        let captured=Date().addingTimeInterval(-86400)
        let snapshot=EntitlementSnapshot(sourceName:"Owned.app",signingIdentifier:"owned.timeline",architecture:.arm64,presence:.dictionaryPresent,origin:.syntheticExample,entitlements:.init(),identity:.init(infoPlist:["CFBundleIdentifier":"owned.timeline","CFBundleShortVersionString":"2.0","CFBundleVersion":"7"]))
        let document=try InspectionDocument(snapshot:snapshot,capturedAt:captured,producerVersion:"1.0-owned-v1")
        let raw=try InspectionDocumentCodec.encode(document)
        let archive=try InspectionArchive(attachments:[.init(id:UUID(),kind:InspectionDocument.kind,schemaVersion:1,mediaType:"application/json",sha256:AssessmentDocument.digest(raw),byteCount:raw.count,bytes:raw)]).encode()
        let added=try await store.addEvidence(archive,to:project.id),reference=try XCTUnwrap(added.evidence.first)
        XCTAssertEqual(reference.extractionTimes,[document.capturedAt])
        XCTAssertGreaterThan(reference.savedAt,captured)
        XCTAssertEqual(reference.producerModels,["extractor: 1.0-owned-v1"])
        XCTAssertTrue(reference.appVersions.contains("app declaration: 2.0"))
        XCTAssertFalse(reference.producerModels.contains("2.0"))
    }
    private func evidence() throws -> Data {
        try ComponentInventoryDocumentCodec.archive(.init(scope:.init(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[]),components:[]))
    }
    private func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-projects-20261020/tests/\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
}
