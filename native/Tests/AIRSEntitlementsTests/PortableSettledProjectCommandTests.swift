import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

/// New command-boundary methods, unrun until a specific qualification allocation.
final class PortableSettledProjectCommandTests:XCTestCase {
    private struct Fixture {
        let root:URL
        let package:URL
        let history:URL
        let project:InspectionProject
        var companion:URL {root.appendingPathComponent("companion")}
        func exportArguments(output:URL?=nil)->[String] {
            ["export","--package",package.path,"--history-store",history.path,
             "--output",(output ?? companion).path,"--confirm-original-evidence"]
        }
    }
    private func fixture() async throws -> Fixture {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-settled-project-cli-20261021-tests", isDirectory: true).path)
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let historyRoot=root.appendingPathComponent("history"),library=EntitlementBatchHistory(root:historyRoot)
        let row=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/absent/Before.app"),current:URL(fileURLWithPath:"/absent/After.app"),architecture:.arm64),
            status:.completed,message:"Synthetic original outcome",changedCount:2,unchangedCount:3,retainedReportID:UUID())
        let cancelled=EntitlementBatchRow(pair:.init(previous:URL(fileURLWithPath:"/absent/OtherBefore.app"),current:URL(fileURLWithPath:"/absent/OtherAfter.app"),architecture:.arm64),status:.cancelled,message:"Synthetic cancellation")
        let record=try EntitlementBatchRecord(result:.init(id:UUID(),rows:[row,cancelled],settled:true,cancelled:true))
        let historyID=try await library.keep(record.data())
        let store=InspectionProjectStore(root:root.appendingPathComponent("source"))
        var project=try await store.create(name:"CLI companion")
        project=try await store.linkBatch(.init(family:.entitlements,historyID:historyID,rowIDs:[row.id,cancelled.id]),to:project.id)
        project=try await store.linkBatch(.init(family:.entitlements,historyID:UUID(),rowIDs:[]),to:project.id)
        project=try await store.linkBatch(.init(family:.audit,historyID:UUID(),rowIDs:[]),to:project.id)
        let package=root.appendingPathComponent("project.airsproject")
        try await store.exportPortableProject(project.id,to:package)
        return .init(root:root,package:package,history:historyRoot,project:project)
    }
    private func object(_ data:Data) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    }
    func testExportAndInspectExposeHistoricalOutcomesWithoutReportsOrQueue() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _=try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        let result=try object(await PortableSettledProjectCommand.run(arguments:["inspect","--companion",f.companion.path]))
        XCTAssertEqual(result["projectID"] as? String,f.project.id.uuidString)
        XCTAssertEqual(result["queueRestored"] as? Bool,false)
        XCTAssertEqual(result["libraryProvenanceAuthenticated"] as? Bool,false)
        XCTAssertEqual(result["comparisonReportsIncluded"] as? Bool,false)
        let outcomes=try XCTUnwrap(result["outcomes"] as? [[String:Any]])
        XCTAssertEqual(outcomes.count,3)
        XCTAssertEqual(outcomes[0]["cancelled"] as? Bool,true)
        XCTAssertEqual(outcomes[1]["absence"] as? String,"missing")
        XCTAssertEqual(outcomes[2]["absence"] as? String,"unsupportedFamily")
        let rows=try XCTUnwrap(outcomes[0]["rows"] as? [[String:Any]])
        XCTAssertEqual(rows.map{$0["status"] as? String},["completed","cancelled"])
        XCTAssertEqual(rows[0]["changedCount"] as? Int,2)
        XCTAssertEqual(rows[0]["unchangedCount"] as? Int,3)
        XCTAssertTrue(rows[1]["changedCount"] is NSNull)
        XCTAssertTrue(rows.allSatisfy {$0["reportIncluded"] as? Bool == false})
        XCTAssertEqual(try Data(contentsOf:f.package.appendingPathComponent("manifest.json")),try Data(contentsOf:f.companion.appendingPathComponent("project.airsproject/manifest.json")))
    }
    func testReconstructCreatesFreshStoreWithExactDetachedHistory() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _=try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        let recipient=f.root.appendingPathComponent("recipient")
        let result=try object(await PortableSettledProjectCommand.run(arguments:["reconstruct","--companion",f.companion.path,"--output",recipient.path]))
        XCTAssertEqual(result["store"] as? String,recipient.path)
        XCTAssertEqual(try Data(contentsOf:recipient.appendingPathComponent("settled-batches.json")),try Data(contentsOf:f.companion.appendingPathComponent("settled-batches.json")))
        do {_=try await PortableSettledProjectCommand.run(arguments:["reconstruct","--companion",f.companion.path,"--output",recipient.path]);XCTFail("Existing store accepted")}catch{}
    }
    func testReexportRequiresExactRecipientWitnessAndPreservesCompanionBytes() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _=try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        let recipient=f.root.appendingPathComponent("recipient")
        _=try await PortableSettledProjectCommand.run(arguments:["reconstruct","--companion",f.companion.path,"--output",recipient.path])
        let output=f.root.appendingPathComponent("reexport")
        let args=["reexport","--package",f.package.path,"--recipient-store",recipient.path,"--output",output.path,"--confirm-original-evidence"]
        _=try await PortableSettledProjectCommand.run(arguments:args)
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("settled-batches.json")),try Data(contentsOf:f.companion.appendingPathComponent("settled-batches.json")))
        _=try await InspectionProjectStore(root:recipient).addAnnotation("Revision changed",acknowledged:false,to:f.project.id)
        let rejected=f.root.appendingPathComponent("rejected")
        var stale=args;stale[6]=rejected.path
        do {_=try await PortableSettledProjectCommand.run(arguments:stale);XCTFail("Stale witness accepted")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:rejected.path))
    }
    func testStrictArgumentsRejectDuplicatesUnknownOptionsAndRelativePaths() async throws {
        let cases:[[String]]=[[],["unknown"],["inspect","--companion","relative"],["inspect","--companion","/missing","--companion","/other"],
            ["inspect","--companion","--output"],["inspect","--companion","/missing","--unknown","value"],
            ["reconstruct","--companion","/missing","--output","relative"],["inspect","--companion"]]
        for args in cases {do {_=try await PortableSettledProjectCommand.run(arguments:args);XCTFail("Accepted invalid arguments: \(args)")}catch{}}
    }
    func testExportAndReexportRequireOriginalEvidenceConfirmation() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        for args in [Array(f.exportArguments().dropLast()),["reexport","--package",f.package.path,"--recipient-store",f.root.path,"--output",f.companion.path]] {
            do {_=try await PortableSettledProjectCommand.run(arguments:args);XCTFail("Missing confirmation accepted")}catch{}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.companion.path))
    }
    func testProtectedHistoryPackageAndExistingDestinationsArePreserved() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        for destination in [f.history.appendingPathComponent("child"),f.package.appendingPathComponent("child"),f.package] {
            do {_=try await PortableSettledProjectCommand.run(arguments:f.exportArguments(output:destination));XCTFail("Protected destination accepted")}catch{}
        }
        _=try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        let original=try Data(contentsOf:f.companion.appendingPathComponent("settled-batches.json"))
        do {_=try await PortableSettledProjectCommand.run(arguments:f.exportArguments());XCTFail("Existing output accepted")}catch{}
        XCTAssertEqual(try Data(contentsOf:f.companion.appendingPathComponent("settled-batches.json")),original)
    }
    func testUnsupportedCompanionSchemaDoesNotPublishRecipient() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _=try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        let file=f.companion.appendingPathComponent("settled-batches.json")
        var value=try object(Data(contentsOf:file));value["schemaVersion"]=2
        try JSONSerialization.data(withJSONObject:value).write(to:file,options:.atomic)
        let recipient=f.root.appendingPathComponent("recipient")
        do {_=try await PortableSettledProjectCommand.run(arguments:["reconstruct","--companion",f.companion.path,"--output",recipient.path]);XCTFail("Unknown schema accepted")}catch{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:recipient.path))
    }
    func testCancelledCommandPublishesNothing() async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let task=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PortableSettledProjectCommand.run(arguments:f.exportArguments())
        }
        do {_=try await task.value;XCTFail("Cancelled command accepted")}catch is CancellationError {}catch {XCTFail("Unexpected cancellation error: \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.companion.path))
    }
}
