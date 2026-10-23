import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class ProjectAdmissionRegressionTests: XCTestCase {
    private func folder() throws -> URL {
        let base=ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-roadmap-admission-20261020", isDirectory: true).path
        let root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func attachment(_ bytes:Data,kind:String=InspectionDocument.kind,media:String="application/json",version:Int=1) -> EvidenceAttachment {
        .init(id:UUID(),kind:kind,schemaVersion:version,mediaType:media,
              sha256:AssessmentDocument.digest(bytes),byteCount:bytes.count,bytes:bytes)
    }
    private func supported() throws -> (Data,Date) {
        let captured=Date(timeIntervalSince1970:1_800_000_000)
        let document=try InspectionDocument(snapshot:ExampleSnapshots.pair(architecture:.arm64).current,
            capturedAt:captured,producerVersion:"0.2.0-admission")
        return (try InspectionDocumentCodec.encode(document),captured)
    }
    func testNonJSONKnownKindsAndFutureSchemaRemainOpaqueWithoutOrphans() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),created=try await store.create(name:"Opaque evidence")
        var items=[EvidenceAttachment]()
        for kind in [InspectionDocument.kind,ComponentInventoryDocumentCodec.kind,"airs.audit",AssessmentDocument.kind] {
            items.append(attachment(Data("opaque-\(kind)".utf8),kind:kind,media:"application/octet-stream"))
        }
        items.append(attachment(Data("future schema".utf8),version:2))
        let raw=try InspectionArchive(attachments:items).encode()
        let archive=try InspectionArchive.decode(raw)
        for item in items {XCTAssertEqual(try archive.validation(for:item.id),.uninterpreted)}
        let added=try await store.addEvidence(raw,to:created.id)
        let reference=try XCTUnwrap(added.evidence.first)
        XCTAssertTrue(reference.extractionTimes.isEmpty);XCTAssertTrue(reference.producerModels.isEmpty);XCTAssertTrue(reference.appVersions.isEmpty)
        XCTAssertEqual(reference.kinds,items.map(\.kind))
        let retained=try await store.evidence(reference.id,in:created.id)
        XCTAssertEqual(retained,raw);XCTAssertEqual(added.revision,created.revision+1)
        let orphans=try await store.unreferencedEvidence();XCTAssertTrue(orphans.isEmpty)
    }
    func testSupportedJSONStillDescribesCaptureAndProducer() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),created=try await store.create(name:"Supported")
        let (bytes,captured)=try supported()
        let raw=try InspectionArchive(attachments:[attachment(bytes)]).encode()
        let added=try await store.addEvidence(raw,to:created.id)
        let reference=try XCTUnwrap(added.evidence.first)
        XCTAssertEqual(reference.extractionTimes,[captured]);XCTAssertEqual(reference.producerModels,["extractor: 0.2.0-admission"])
        let retained=try await store.evidence(reference.id,in:created.id);XCTAssertEqual(retained,raw)
    }
    func testMalformedKnownJSONDeclinesBeforeRetentionAndRevision() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),created=try await store.create(name:"Malformed")
        let opaque=try InspectionArchive(attachments:[attachment(Data("not-json".utf8),media:"application/octet-stream")]).encode()
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:opaque) as? [String:Any])
        var entries=try XCTUnwrap(object["attachments"] as? [[String:Any]])
        entries[0]["mediaType"]="application/json";object["attachments"]=entries
        let malformed=try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)
        do {_=try await store.addEvidence(malformed,to:created.id);XCTFail("Malformed known JSON admitted")} catch {}
        let loaded=try await store.load(created.id),orphans=try await store.unreferencedEvidence()
        XCTAssertEqual(loaded.revision,created.revision);XCTAssertTrue(loaded.evidence.isEmpty);XCTAssertTrue(orphans.isEmpty)
    }
    func testLaterPublicationFailurePreservesSharedEvidenceAndReceipt() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root),first=try await store.create(name:"Existing"),second=try await store.create(name:"Later")
        let (bytes,_)=try supported(),raw=try InspectionArchive(attachments:[attachment(bytes)]).encode()
        let added=try await store.addEvidence(raw,to:first.id),id=try XCTUnwrap(added.evidence.first?.id)
        let receipt=root.appendingPathComponent("Evidence/\(id.uuidString)/receipt.json"),original=try Data(contentsOf:receipt)
        let failing=InspectionProjectStore(root:root,publish:{_,_ in throw CocoaError(.fileWriteUnknown)})
        do {_=try await failing.addEvidence(raw,to:second.id);XCTFail("Injected publication succeeded")} catch {}
        let existing=try await store.load(first.id),later=try await store.load(second.id),retained=try await store.evidence(id)
        XCTAssertEqual(existing.evidence.first?.id,id);XCTAssertEqual(later.revision,second.revision);XCTAssertTrue(later.evidence.isEmpty)
        XCTAssertEqual(try Data(contentsOf:receipt),original);XCTAssertEqual(retained,raw)
    }
}
