import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class PortableProjectTests: XCTestCase {
    func root() throws -> URL {
        let url = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("c5-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    func evidence() throws -> Data {
        let document = try InspectionDocumentCodec.encode(.init(snapshot:ExampleSnapshots.pair(architecture:.arm64).current,
            capturedAt:Date(timeIntervalSince1970:1_800_000_000),producerVersion:"0.2.0-c5-synthetic"))
        return try InspectionArchive(attachments:[.init(id:UUID(),kind:"airs.inspection",schemaVersion:1,mediaType:"application/json",
            sha256:AssessmentDocument.digest(document),byteCount:document.count,bytes:document)]).encode()
    }
    func fixture(_ root: URL) async throws -> (InspectionProjectStore,InspectionProject,Data,URL) {
        let store = InspectionProjectStore(root:root.appendingPathComponent("source")), bytes = try evidence()
        var project = try await store.create(name:"Portable synthetic review")
        project = try await store.addEvidence(bytes,to:project.id)
        project = try await store.pinBaseline(project.evidence[0].id,in:project.id)
        project = try await store.addAnnotation("Original note",acknowledged:true,to:project.id)
        project = try await store.linkBatch(.init(family:.audit,historyID:UUID(),rowIDs:[UUID()]),to:project.id)
        let package = root.appendingPathComponent("review.airsproject")
        try await store.exportPortableProject(project.id,to:package)
        return (store,project,bytes,package)
    }
    func mutate(_ file: URL,_ change: (inout [String:Any]) -> Void) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]); change(&object)
        try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:file)
    }
    func testFreshReconstructionWithoutSourcePreservesIdentityHistoryAndBytes() async throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let (_,source,bytes,package)=try await fixture(root)
        let inventory=try PortableProjectReader.inventory(at:package)
        XCTAssertEqual(inventory.projectID,source.id);XCTAssertEqual(inventory.evidence.count,1)
        try FileManager.default.removeItem(at:root.appendingPathComponent("source"))
        let destination=root.appendingPathComponent("recipient")
        let store=try await PortableProjectReader.reconstruct(at:package,to:destination)
        let restored=try await store.load(source.id)
        XCTAssertEqual(try restored.data(),try source.data())
        let retained=try await store.evidence(source.evidence[0].id,in:source.id)
        XCTAssertEqual(retained,bytes)
        let reexport=root.appendingPathComponent("again.airsproject")
        try await store.exportPortableProject(source.id,to:reexport)
        let path=inventory.evidence[0].path
        XCTAssertEqual(try Data(contentsOf:reexport.appendingPathComponent(path)),bytes)
        XCTAssertEqual(try Data(contentsOf:package.appendingPathComponent("project.json")),try Data(contentsOf:reexport.appendingPathComponent("project.json")))
        XCTAssertEqual(restored.batchLinks.count,1,"Historical link only; no batch queue reconstruction")
    }
    func testExistingDestinationIsNeverOverwrittenAndFailureCleansStage() async throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let (source,project,_,package)=try await fixture(root)
        do {try await source.exportPortableProject(project.id,to:package);XCTFail("Existing export") } catch {}
        let target=root.appendingPathComponent("recipient");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let sentinel=target.appendingPathComponent("keep");try Data("original".utf8).write(to:sentinel)
        do {_=try await PortableProjectReader.reconstruct(at:package,to:target);XCTFail("Existing store") } catch {}
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("original".utf8))
        let failed=root.appendingPathComponent("failed")
        do {_=try await PortableProjectReader.reconstruct(at:package,to:failed,beforePublish:{throw CocoaError(.fileWriteUnknown)});XCTFail("Injected failure") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:failed.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".airsproject-")})
    }
    func testTraversalAliasesDuplicatesAndUnexpectedEntriesDecline() async throws {
        for path in ["../outside","/tmp/outside","evidence/../project.json","EVIDENCE/invalid.airsreview"] {
            let root=try root();defer {try? FileManager.default.removeItem(at:root)}
            let (_,_,_,package)=try await fixture(root)
            try mutate(package.appendingPathComponent("manifest.json")) { object in
                var entries=object["evidence"] as! [[String:Any]];entries[0]["path"]=path;object["evidence"]=entries
            }
            XCTAssertThrowsError(try PortableProjectReader.inventory(at:package),path)
        }
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let (_,_,_,package)=try await fixture(root)
        try mutate(package.appendingPathComponent("manifest.json")) {object in let rows=object["evidence"] as! [[String:Any]];object["evidence"]=rows+rows}
        XCTAssertThrowsError(try PortableProjectReader.inventory(at:package))
    }
    func testDigestLengthVersionTruncationAndLinksDeclineBeforePublishing() async throws {
        for fault in ["digest","length","version","truncated","link","extra","bool"] {
            let root=try root();defer {try? FileManager.default.removeItem(at:root)}
            let (_,_,_,package)=try await fixture(root)
            let manifest=package.appendingPathComponent("manifest.json")
            let inventory=try PortableProjectReader.inventory(at:package),payload=package.appendingPathComponent(inventory.evidence[0].path)
            switch fault {
            case "digest":try Data("changed".utf8).write(to:payload)
            case "length":try mutate(manifest){o in var rows=o["evidence"] as! [[String:Any]];rows[0]["bytes"]=1;o["evidence"]=rows}
            case "version":try mutate(manifest){$0["schemaVersion"]=2}
            case "bool":try mutate(manifest){$0["schemaVersion"]=true}
            case "truncated":try Data("{".utf8).write(to:manifest)
            case "extra":try Data().write(to:package.appendingPathComponent("extra"))
            default:
                let external=root.appendingPathComponent("external");try FileManager.default.moveItem(at:payload,to:external)
                try FileManager.default.createSymbolicLink(at:payload,withDestinationURL:external)
            }
            let destination=root.appendingPathComponent("recipient")
            do {_=try await PortableProjectReader.reconstruct(at:package,to:destination);XCTFail(fault)} catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path),fault)
        }
    }
    func testCancellationAndBudgetRefusalPreserveSource() async throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        let (_,project,bytes,package)=try await fixture(root),destination=root.appendingPathComponent("recipient")
        let task=Task {try await PortableProjectReader.reconstruct(at:package,to:destination,beforePublish:{throw CancellationError()})}
        do {_=try await task.value;XCTFail("Cancelled publication")} catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        let source=InspectionProjectStore(root:root.appendingPathComponent("source"))
        let retained=try await source.evidence(project.evidence[0].id);XCTAssertEqual(retained,bytes)
        XCTAssertThrowsError(try PortableProjectReader.inventory(at:package,maximumBytes:1))
    }
}

final class PortableProjectCommandTests: XCTestCase {
    func testPreviewConfirmationAndFreshReconstructionCommand() async throws {
        let helper=PortableProjectTests(),root=try helper.root();defer {try? FileManager.default.removeItem(at:root)}
        let (_,project,_,package)=try await helper.fixture(root)
        let store=root.appendingPathComponent("source"),output=root.appendingPathComponent("cli.airsproject")
        let preview=try await PortableProjectCommand.run(arguments:["preview","--store",store.path,"--project",project.id.uuidString])
        XCTAssertTrue(String(decoding:preview,as:UTF8.self).contains("originalBinariesIncluded"))
        do {_=try await PortableProjectCommand.run(arguments:["export","--store",store.path,"--project",project.id.uuidString,"--output",output.path]);XCTFail("Confirmation required")} catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        _=try await PortableProjectCommand.run(arguments:["export","--store",store.path,"--project",project.id.uuidString,"--output",output.path,"--confirm-original-evidence"])
        let fresh=root.appendingPathComponent("cli-recipient")
        let result=try await PortableProjectCommand.run(arguments:["reconstruct","--package",package.path,"--output",fresh.path])
        XCTAssertTrue(String(decoding:result,as:UTF8.self).contains(project.id.uuidString))
        let restored=try await InspectionProjectStore(root:fresh).load(project.id)
        XCTAssertEqual(restored.pinnedBaselineID,project.pinnedBaselineID)
        for args in [["preview","--store",store.path,"--store",store.path],["export","--unknown","value"],["reconstruct","--package",package.path,"--output",fresh.path]] {
            do {_=try await PortableProjectCommand.run(arguments:args);XCTFail("Invalid or existing target")} catch {}
        }
    }
}

final class PortableProjectExecutableTests: XCTestCase {
    func testNativeCommandExportsAndReconstructsFreshStore() async throws {
        let helper=PortableProjectTests(),root=try helper.root()
        // Retain this newly authored synthetic demo and its receipts for review.
        let (_,project,bytes,_)=try await helper.fixture(root)
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable=repository.appendingPathComponent("native/.build/debug/airs-entitlements")
        let package=root.appendingPathComponent("native.airsproject"),fresh=root.appendingPathComponent("native-recipient")
        func run(_ arguments:[String],name:String) throws {
            let log=root.appendingPathComponent(name+".json");try Data().write(to:log)
            let handle=try FileHandle(forWritingTo:log);defer {try? handle.close()}
            let task=Process();task.executableURL=executable;task.arguments=["project"]+arguments
            task.standardOutput=handle;task.standardError=handle
            try task.run();task.waitUntilExit()
            let diagnostic=String(decoding:try Data(contentsOf:log),as:UTF8.self)
            XCTAssertEqual(task.terminationStatus,0,diagnostic)
        }
        try run(["preview","--store",root.appendingPathComponent("source").path,"--project",project.id.uuidString],name:"preview")
        try run(["export","--store",root.appendingPathComponent("source").path,"--project",project.id.uuidString,"--output",package.path,"--confirm-original-evidence"],name:"export")
        try FileManager.default.removeItem(at:root.appendingPathComponent("source"))
        try run(["reconstruct","--package",package.path,"--output",fresh.path],name:"reconstruct")
        let retained=try await InspectionProjectStore(root:fresh).evidence(project.evidence[0].id,in:project.id)
        XCTAssertEqual(retained,bytes)
        let receipt:[String:Any]=["demoRoot":root.path,"projectID":project.id.uuidString,"package":package.path,"freshStore":fresh.path,"sourceStoreRemoved":true,"originalAppsUsed":false,"nativeCommandExitStatuses":[0,0,0]]
        let output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("native-demo.json")
        try JSONSerialization.data(withJSONObject:receipt,options:.prettyPrinted).write(to:output)
    }
}
