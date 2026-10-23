import XCTest
import AIRSCore
@testable import AIRSEntitlements

final class PortableProjectPreflightTests: XCTestCase {
    private func folder() throws -> URL {
        let base=ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-C5-manifest-preflight-20261020", isDirectory: true).path
        let root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func testNoncanonicalManifestSurvivesExportReconstructionAndReexport() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root.appendingPathComponent("source"))
        var project=try await store.create(name:"Exact source metadata")
        let bytes=try ComponentInventoryDocumentCodec.archive(.init(scope:.init(searchedLocations:["Contents/MacOS"],completion:.completeWithinScope,exclusions:[],issues:[]),components:[]))
        project=try await store.addEvidence(bytes,to:project.id)
        project=try await store.pinBaseline(project.evidence[0].id,in:project.id)
        project=try await store.addAnnotation("Original",acknowledged:false,to:project.id)
        project=try await store.addAnnotation("Correction",acknowledged:true,to:project.id,supersedes:project.annotationIDs[0])
        project=try await store.linkBatch(.init(family:.audit,historyID:UUID(),rowIDs:[UUID()]),to:project.id)
        let original=try project.data(),object=try JSONSerialization.jsonObject(with:original)
        var sourceBytes=Data(" \n\t".utf8)
        sourceBytes.append(try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]))
        sourceBytes.append(Data("\n \n".utf8))
        XCTAssertNotEqual(sourceBytes,original)
        let sourceManifest=store.storageRoot.appendingPathComponent("Projects/\(project.id.uuidString)/manifest.json")
        try sourceBytes.write(to:sourceManifest,options:.atomic)
        let package=root.appendingPathComponent("first.airsproject")
        try await store.exportPortableProject(project.id,to:package,expectedRevision:project.revision)
        XCTAssertEqual(try Data(contentsOf:package.appendingPathComponent("project.json")),sourceBytes)
        let recipient=root.appendingPathComponent("recipient")
        let restored=try await PortableProjectReader.reconstruct(at:package,to:recipient)
        XCTAssertEqual(try Data(contentsOf:recipient.appendingPathComponent("Projects/\(project.id.uuidString)/manifest.json")),sourceBytes)
        let loaded=try await restored.load(project.id)
        XCTAssertEqual(loaded.pinnedBaselineID,project.pinnedBaselineID)
        XCTAssertEqual(loaded.annotationIDs,project.annotationIDs);XCTAssertEqual(loaded.history,project.history)
        let reexport=root.appendingPathComponent("second.airsproject")
        try await restored.exportPortableProject(project.id,to:reexport)
        XCTAssertEqual(try Data(contentsOf:reexport.appendingPathComponent("project.json")),sourceBytes)
        XCTAssertEqual(try Data(contentsOf:sourceManifest),sourceBytes)
    }
    private func writerFixture() throws -> (InspectionProject,Data,[UUID:Data]) {
        var project=InspectionProject(name:"New staged artifact")
        let content=Data("opaque source".utf8)
        let archive=try InspectionArchive(attachments:[.init(id:UUID(),kind:"future.opaque",schemaVersion:1,mediaType:"application/octet-stream",sha256:AssessmentDocument.digest(content),byteCount:content.count,bytes:content)]).encode()
        let id=UUID()
        project.evidence=[.init(id:id,digest:AssessmentDocument.digest(archive),savedAt:Date(),extractionTimes:[],producerModels:[],appVersions:[],kinds:["future.opaque"])]
        return (project,try project.data(),[id:archive])
    }
    func testStagedMutationsRefusePublicationAndCleanOwnedStage() throws {
        for fault in ["metadata","evidence","extra","manifest","link"] {
            let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
            let (project,metadata,evidence)=try writerFixture(),target=root.appendingPathComponent("declined.airsproject")
            let original=root.appendingPathComponent("original");try metadata.write(to:original)
            XCTAssertThrowsError(try PortableProjectWriter.write(project:project,metadata:metadata,evidence:evidence,to:target,beforePreflight:{stage in
                switch fault {
                case "metadata":try Data("{}".utf8).write(to:stage.appendingPathComponent("project.json"))
                case "evidence":try Data("changed archive".utf8).write(to:stage.appendingPathComponent(PortableProjectInventory.path(project.evidence[0].id)))
                case "manifest":try Data("{}".utf8).write(to:stage.appendingPathComponent("manifest.json"))
                case "link":
                    let file=stage.appendingPathComponent("project.json");try FileManager.default.removeItem(at:file)
                    try FileManager.default.createSymbolicLink(at:file,withDestinationURL:original)
                default:try Data("extra".utf8).write(to:stage.appendingPathComponent("unexpected"))
                }
            }),fault)
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path),fault)
            XCTAssertEqual(try Data(contentsOf:original),metadata)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".airsproject-")})
        }
    }
    func testDigestConsistentMalformedKnownPayloadDeclinesNativePreflight() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        var (project,_,evidence)=try writerFixture()
        let id=project.evidence[0].id
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:evidence[id]!) as? [String:Any])
        var entries=try XCTUnwrap(wire["attachments"] as? [[String:Any]])
        entries[0]["kind"]=InspectionDocument.kind;entries[0]["mediaType"]="application/json";wire["attachments"]=entries
        let malformed=try JSONSerialization.data(withJSONObject:wire,options:.sortedKeys)
        project.evidence=[.init(id:id,digest:AssessmentDocument.digest(malformed),savedAt:Date(),extractionTimes:[],producerModels:[],appVersions:[],kinds:[InspectionDocument.kind])]
        evidence[id]=malformed
        let target=root.appendingPathComponent("invalid.airsproject")
        XCTAssertThrowsError(try PortableProjectWriter.write(project:project,metadata:project.data(),evidence:evidence,to:target))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }

    func testValidReboundMetadataStillRefusesSubstitution() throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let (project,metadata,evidence)=try writerFixture(),target=root.appendingPathComponent("substitution.airsproject")
        XCTAssertThrowsError(try PortableProjectWriter.write(project:project,metadata:metadata,evidence:evidence,to:target,beforePreflight:{stage in
            var changed=project;changed.name="Different valid project metadata"
            let replacement=try changed.data()
            try replacement.write(to:stage.appendingPathComponent("project.json"))
            let file=stage.appendingPathComponent("manifest.json")
            var manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
            manifest["metadata"]=["path":"project.json","sha256":AssessmentDocument.digest(replacement),"bytes":replacement.count]
            try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys).write(to:file)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    func testInjectedFailureCancellationAndLateDestinationPreserveInputs() throws {
        for mode in ["failure","cancellation","destination"] {
            let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
            let (project,metadata,evidence)=try writerFixture(),target=root.appendingPathComponent("target.airsproject")
            let sentinel=target.appendingPathComponent("owned-sentinel")
            XCTAssertThrowsError(try PortableProjectWriter.write(project:project,metadata:metadata,evidence:evidence,to:target,beforePreflight:{_ in
                if mode == "failure" {throw CocoaError(.fileWriteUnknown)}
                if mode == "cancellation" {throw CancellationError()}
                try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
                try Data("preserve destination".utf8).write(to:sentinel)
            }))
            if mode == "destination" {
                XCTAssertEqual(try Data(contentsOf:sentinel),Data("preserve destination".utf8))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:target.path),["owned-sentinel"])
            } else {XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))}
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".airsproject-")})
        }
    }

}
