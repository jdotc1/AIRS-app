import XCTest
@testable import AIRSEntitlements

final class InspectionProjectCatalogCommandTests:XCTestCase {
    private func root() throws -> URL {
        let base=ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-project-catalog-20261022-tests", isDirectory: true).path
        let root=URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    private func keep(_ project:InspectionProject,in root:URL) throws -> URL {
        let folder=root.appendingPathComponent("Projects/"+project.id.uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent("manifest.json")
        try (Data(" \n".utf8)+project.data()).write(to:file);return file
    }
    private func catalog(_ root:URL) async throws -> [String:Any] {
        let data=try await PortableProjectCommand.run(arguments:["catalog","--store",root.path])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func testCatalogPreservesBytesAndDoesNotReadOriginalEvidence() async throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        var p=InspectionProject(name:"Owned catalog project")
        p.evidence=[.init(id:UUID(),digest:String(repeating:"0",count:64),savedAt:p.createdAt,
            extractionTimes:[],producerModels:[],appVersions:[],kinds:["airs.inspection"])]
        p.annotations=[.init(text:"Keep original note",acknowledged:false)]
        p.annotationIDs=p.annotations.map(\.id)
        p.batchLinks=[.init(family:.audit,historyID:UUID(),rowIDs:[])]
        let file=try keep(p,in:r),bytes=try Data(contentsOf:file)
        let result=try await catalog(r)
        let row=try XCTUnwrap((result["projects"] as? [[String:Any]])?.first)
        XCTAssertEqual(row["projectID"] as? String,p.id.uuidString)
        XCTAssertEqual(row["evidenceReferenceCount"] as? Int,1)
        XCTAssertEqual(row["annotationCount"] as? Int,1)
        XCTAssertEqual(row["historicalBatchLinkCount"] as? Int,1)
        for flag in ["evidenceValidated","historicalOutcomesResolved","queueRestored","atomicSnapshot"] {
            XCTAssertEqual(result[flag] as? Bool,false)
        }
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent("Evidence").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent(".lease").path))
    }
    func testCatalogRetainsCorruptAndSymlinkEntriesWithDeterministicIdentity() async throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        _=try keep(InspectionProject(name:"Same name"),in:r)
        _=try keep(InspectionProject(name:"Same name"),in:r)
        let bad=UUID(),linked=UUID(),oversized=UUID(),outside=r.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let badFolder=r.appendingPathComponent("Projects/"+bad.uuidString)
        try FileManager.default.createDirectory(at:badFolder,withIntermediateDirectories:false)
        try Data("broken".utf8).write(to:badFolder.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at:r.appendingPathComponent("Projects/"+linked.uuidString),withDestinationURL:outside)
        let big=r.appendingPathComponent("Projects/"+oversized.uuidString)
        try FileManager.default.createDirectory(at:big,withIntermediateDirectories:false)
        try Data(repeating:32,count:2_097_153).write(to:big.appendingPathComponent("manifest.json"))
        let result=try await catalog(r),rows=try XCTUnwrap(result["projects"] as? [[String:Any]])
        XCTAssertEqual(result["projectCount"] as? Int,5)
        XCTAssertEqual(result["readableCount"] as? Int,2);XCTAssertEqual(result["unreadableCount"] as? Int,3)
        let ids=rows.compactMap{$0["projectID"] as? String};XCTAssertEqual(ids,ids.sorted())
        for id in [bad,linked,oversized] {
            let row=try XCTUnwrap(rows.first{$0["projectID"] as? String == id.uuidString})
            XCTAssertNotNil(row["issue"] as? String);XCTAssertNil(row["name"])
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:outside.path).isEmpty)
    }
    func testCatalogRejectsMissingAliasedAndNonDirectoryRootsWithoutCreation() async throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let missing=r.appendingPathComponent("missing"),file=r.appendingPathComponent("file"),alias=r.appendingPathComponent("alias")
        try Data("keep".utf8).write(to:file)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:r)
        for target in [missing,file,alias,alias.appendingPathComponent("child")] {
            do {_=try await catalog(target);XCTFail("Unsafe root accepted")} catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"keep")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:r.path)),["file","alias"])
        let linkedStore=r.appendingPathComponent("linked-store")
        try FileManager.default.createDirectory(at:linkedStore,withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:linkedStore.appendingPathComponent("Projects"),withDestinationURL:r)
        do {_=try await catalog(linkedStore);XCTFail("Linked Projects accepted")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:linkedStore.appendingPathComponent(".lease").path))
        let danglingStore=r.appendingPathComponent("dangling-store")
        try FileManager.default.createDirectory(at:danglingStore,withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:danglingStore.appendingPathComponent("Projects"),withDestinationURL:missing)
        do {_=try await catalog(danglingStore);XCTFail("Dangling Projects accepted")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path))
    }
    func testCatalogRejectsStrictArgumentsAndConfirmation() async throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let empty=try await catalog(r);XCTAssertEqual(empty["projectCount"] as? Int,0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:r.path).isEmpty)
        let invalid:[[String]]=[[],["--store"],["--store","relative"],["--store",r.path,"--store","/other"],
            ["--store",r.path,"--project",UUID().uuidString],["--store",r.path,"--confirm-original-evidence"],
            ["--unknown","/absent"],["--store",r.path,"extra"]]
        for args in invalid {
            do {_=try await PortableProjectCommand.run(arguments:["catalog"]+args);XCTFail("Invalid arguments accepted")}catch{}
        }
    }
    func testCatalogBoundsProjectCountAndImmediateDirectoryWork() async throws {
        for unrelated in [false,true] {
            let r=try root();defer{try? FileManager.default.removeItem(at:r)}
            let folder=r.appendingPathComponent("Projects");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
            for i in 0..<(unrelated ? 129:65) {
                try Data().write(to:folder.appendingPathComponent(unrelated ? "extra-\(i)":UUID().uuidString))
            }
            do {_=try await catalog(r);XCTFail("Unbounded inventory accepted")}catch{}
            XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent(".lease").path))
        }
    }
    func testCatalogCancellationDoesNotCreateOrPublishStore() async throws {
        let r=try root();defer{try? FileManager.default.removeItem(at:r)}
        let target=r.appendingPathComponent("not-created")
        let task=Task {
            withUnsafeCurrentTask{$0?.cancel()}
            return try await PortableProjectCommand.run(arguments:["catalog","--store",target.path])
        }
        do {_=try await task.value;XCTFail("Cancelled catalog returned output")} catch is CancellationError {} catch {XCTFail("Cancellation relabeled: \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
}
