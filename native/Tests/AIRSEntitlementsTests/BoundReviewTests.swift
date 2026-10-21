import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class BoundReviewTests: XCTestCase {
    let findingID = "airsf-" + String(repeating: "a", count: 64)
    func report(config: String = #", "analysis_config":{"limits":{"max_functions":12}}"#) -> Data {
        Data("""
         {"schema_version":1,"report_kind":"airs.audit",
         "generator":{"name":"AIRS","version":"synthetic-c4","analysis_model_version":"synthetic-opaque-model"},
         "image":{"display_name":"synthetic-c4.dylib","architecture":"arm64","cpu_subtype":0,"uuid":null,
         "container_sha256":"\(String(repeating:"1",count:64))","slice_sha256":"\(String(repeating:"2",count:64))",
         "slice_offset":0,"slice_size":4096,"preferred_base":"0x0","file_type":"dylib"},
         "summary":{"function_count":1,"agreement_count":0,"inconsistency_count":0,"unresolved_count":1,"metadata_entry_count":0,"checked_pc_count":0},
         "issues":[],"metadata_ranges":[],"limitations":["Synthetic transport data only"],
         "findings":[{"id":"\(findingID)","function":{"name":"_synthetic_c4","address":"0x100","end_address":"0x110","image_offset":"0x100","size":16,"boundary_source":"lc_function_starts"},
         "instruction_count":4,"encoding":"0x0","coverage":"none","mode":"none","scope":"metadata_only","verdict":"unresolved",
         "checked_pcs":[],"reason_codes":["synthetic"],"evidence":[],"limitations":["No recovery claim"]}]\(config)}
        \n
        """.utf8)
    }
    func request() throws -> BoundReviewRequest { try .create(report: report(), findingID: findingID) }
    func json(_ bytes: Data) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any]) }
    func bytes(_ object: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) }
    func ack(_ request: BoundReviewRequest, outcome: String = "navigated") throws -> [String:Any] {
        let object = try json(request.requestBytes)
        let source = try XCTUnwrap(object["source_report"])
        var destination = try XCTUnwrap((object["projection"] as? [String:Any])?["image"] as? [String:Any])
        destination.removeValue(forKey:"display_name"); destination["image_id"] = UUID().uuidString
        return ["report_kind":BoundReviewAcknowledgment.kind,"schema_version":1,
            "acknowledgment_id":UUID().uuidString,
            "request":["request_id":request.requestID.uuidString.lowercased(),"sha256":request.requestDigest,"byte_count":request.requestBytes.count],
            "untrusted_request_id":NSNull(),"source_report":source,"finding_id":findingID,
            "consumer":["bundle_id":"example.synthetic.consumer","version":"test","build":"1","source_revision":NSNull(),"build_provenance_state":"unavailable"],
            "profile":BoundReviewRequest.profile,"completed_at":"2026-10-20T23:00:00Z","outcome":outcome,
            "code":outcome == "navigated" ? "navigation_completed" : "user_cancelled","admission":"destination_verified",
            "destination":destination,
            "navigation":outcome == "navigated" ? ["requested_start":"0x100","selected_start":"0x100","selected_image_id":destination["image_id"]!] : NSNull(),
            "semantics":"source_reported_not_consumer_verified","diagnostic":"Synthetic consumer receipt, not MacScope acceptance"]
    }
    func testOriginalBytesAndMissingConfigurationRoundTrip() throws {
        for config in ["", #", "analysis_config":{"limits":{"max_functions":12}}"#] {
            let original = report(config:config)
            let created = try BoundReviewRequest.create(report:original,findingID:findingID)
            let decoded = try BoundReviewRequest.decodeArchive(created.archiveBytes)
            XCTAssertEqual(decoded.reportBytes,original)
            XCTAssertEqual(decoded.requestBytes,created.requestBytes)
            let configuration = try XCTUnwrap(try json(decoded.requestBytes)["configuration"] as? [String:Any])
            XCTAssertEqual(configuration["state"] as? String,config.isEmpty ? "not_recorded" : "recorded")
        }
    }
    func testConfigurationRejectsBooleanFloatNullAndUnknownShapes() {
        for config in [#", "analysis_config":null"#, #", "analysis_config":{"limits":{"x":true}}"#,
                       #", "analysis_config":{"limits":{"x":1.0}}"#, #", "analysis_config":{"limits":{"x":1e0}}"#,
                       #", "analysis_config":{"limits":{},"future":3}"#] {
            XCTAssertThrowsError(try BoundReviewRequest.create(report:report(config:config),findingID:findingID),config)
        }
    }
    func testRequestCannotBindChangedReportProjectionOrConfiguration() throws {
        let valid = try request(), archive = try InspectionArchive.decode(valid.archiveBytes)
        for key in ["finding_id","configuration","projection","source_report","schema_version","extra"] {
            var object = try json(valid.requestBytes)
            switch key {
            case "finding_id": object[key] = "airsf-" + String(repeating:"b",count:64)
            case "configuration": object[key] = ["state":"not_recorded"]
            case "projection": var p = try XCTUnwrap(object[key] as? [String:Any]); p["source_analysis"] = ["name":"forged"]; object[key] = p
            case "source_report": var d = try XCTUnwrap(object[key] as? [String:Any]); d["sha256"] = String(repeating:"0",count:64); object[key] = d
            case "schema_version": object[key] = true
            default: object[key] = "ignored?"
            }
            let payload = try bytes(object)
            let changed = archive.attachments.map { item in item.kind == BoundReviewRequest.kind ? EvidenceAttachment(id:item.id,kind:item.kind,schemaVersion:1,mediaType:"application/json",sha256:AssessmentDocument.digest(payload),byteCount:payload.count,bytes:payload) : item }
            XCTAssertThrowsError(try BoundReviewRequest.decodeArchive(InspectionArchive(attachments:changed).encode()),key)
        }
    }
    func testWhitespaceChangeCannotReuseOldSourceDescriptor() throws {
        let valid = try request(), archive = try InspectionArchive.decode(valid.archiveBytes)
        let changed = archive.attachments.map { item in
            let data = item.kind == "airs.audit" ? item.bytes + Data(" ".utf8) : item.bytes
            return EvidenceAttachment(id:item.id,kind:item.kind,schemaVersion:1,mediaType:"application/json",sha256:AssessmentDocument.digest(data),byteCount:data.count,bytes:data)
        }
        XCTAssertThrowsError(try BoundReviewRequest.decodeArchive(InspectionArchive(attachments:changed).encode()))
    }
    func testDuplicateKeysFindingsAndReceiverLimitsDecline() throws {
        let duplicate = String(decoding:report(),as:UTF8.self).replacingOccurrences(of:#""schema_version":1"#,with:#""schema_version":1,"schema_version":1"#)
        XCTAssertThrowsError(try BoundReviewRequest.create(report:Data(duplicate.utf8),findingID:findingID))
        var root = try json(report()); let finding = try XCTUnwrap((root["findings"] as? [[String:Any]])?.first)
        root["findings"] = [finding,finding]
        XCTAssertThrowsError(try BoundReviewRequest.create(report:bytes(root),findingID:findingID))
        root = try json(report()); root["generator"] = ["name":"AIRS","version":"test","analysis_model_version":String(repeating:"x",count:257)]
        XCTAssertThrowsError(try BoundReviewRequest.create(report:bytes(root),findingID:findingID))
    }
    func testAcknowledgmentSuccessCancellationAndExactCorrelation() throws {
        let request = try request()
        for outcome in ["navigated","cancelled"] {
            let receipt = try BoundReviewAcknowledgment.decode(bytes(ack(request,outcome:outcome)))
            XCTAssertTrue(try receipt.matches(request))
            XCTAssertEqual(receipt.outcome,outcome)
        }
        var wrong = try ack(request); var descriptor = try XCTUnwrap(wrong["request"] as? [String:Any]); descriptor["sha256"] = String(repeating:"f",count:64); wrong["request"] = descriptor
        XCTAssertFalse(try BoundReviewAcknowledgment.decode(bytes(wrong)).matches(request))
        wrong = try ack(request); wrong["finding_id"] = "airsf-" + String(repeating:"b",count:64)
        XCTAssertFalse(try BoundReviewAcknowledgment.decode(bytes(wrong)).matches(request))
    }
    func testMalformedSuccessStaleDestinationAndForgedImageDecline() throws {
        let request = try request()
        for field in ["navigation","request","source_report","destination","admission","extra","schema_version"] {
            var object = try ack(request)
            object[field] = field == "admission" ? "source_bound" : (field == "schema_version" ? true : NSNull())
            XCTAssertThrowsError(try BoundReviewAcknowledgment.decode(bytes(object)),field)
        }
        var stale = try ack(request); stale["outcome"] = "rejected"; stale["code"] = "stale_destination"; stale["navigation"] = NSNull()
        XCTAssertThrowsError(try BoundReviewAcknowledgment.decode(bytes(stale)))
        stale["destination"] = NSNull(); stale["admission"] = "source_bound"
        XCTAssertTrue(try BoundReviewAcknowledgment.decode(bytes(stale)).matches(request))
        var image = try ack(request), dest = try XCTUnwrap(image["destination"] as? [String:Any]); dest["container_sha256"] = String(repeating:"f",count:64); image["destination"] = dest
        XCTAssertThrowsError(try BoundReviewAcknowledgment.decode(bytes(image)).matches(request))
        var nav = try ack(request); nav["navigation"] = ["requested_start":"0x100","selected_start":"0x104","selected_image_id":dest["image_id"]!]
        XCTAssertThrowsError(try BoundReviewAcknowledgment.decode(bytes(nav)))
    }
    func testUnboundRejectionRemainsUnassociated() throws {
        let request = try request(); var object = try ack(request)
        for field in ["request","source_report","finding_id","destination","navigation"] { object[field] = NSNull() }
        object["outcome"] = "rejected"; object["code"] = "invalid_source_report"; object["admission"] = "not_validated"
        object["untrusted_request_id"] = request.requestID.uuidString
        XCTAssertFalse(try BoundReviewAcknowledgment.decode(bytes(object)).matches(request))
    }
    func testLedgerPersistsExactRequestsAndAcknowledgmentsWithoutReplacingConflicts() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("AIRS-C4-bound-tests").appendingPathComponent("c4-tests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger = BoundReviewLedger(root:root), request = try request(), receipt = try bytes(ack(request))
        try await ledger.retain(request)
        let first = try await ledger.importAcknowledgment(receipt)
        XCTAssertTrue(first.associated)
        let repeated = try await ledger.importAcknowledgment(receipt)
        XCTAssertTrue(repeated.associated)
        var conflicting = try json(receipt); conflicting["diagnostic"] = "Different bytes for same ID"
        do { _ = try await ledger.importAcknowledgment(bytes(conflicting)); XCTFail("Must preserve first receipt") } catch {}
        let reopened = BoundReviewLedger(root:root)
        let entries = try await reopened.entries()
        XCTAssertEqual(entries.count,1); XCTAssertTrue(entries[0].associated)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("requests/"+request.requestID.uuidString.lowercased()+".airsreview")),request.archiveBytes)
    }
    func testRetainedReplacementInvalidatesCaches() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("AIRS-C4-bound-tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger = BoundReviewLedger(root:root), request = try request(), receipt = try bytes(ack(request))
        try await ledger.retain(request)
        _ = try await ledger.importAcknowledgment(receipt)
        let file = root.appendingPathComponent("requests/"+request.requestID.uuidString.lowercased()+".airsreview")
        try FileManager.default.removeItem(at:file)
        let absent = try await ledger.importAcknowledgment(receipt)
        XCTAssertFalse(absent.associated,"Deleted request cannot remain retained merely through a cache")
        let receiptID = try BoundReviewAcknowledgment.decode(receipt).id
        let saved = root.appendingPathComponent("acknowledgments/"+receiptID.uuidString.lowercased()+".json")
        try Data("{}".utf8).write(to:saved,options:.atomic)
        do { _ = try await ledger.entries(); XCTFail("Changed receipt must be admitted afresh, not hidden by cache") } catch {}
    }

    func testNativeProjectionMatchesExistingPythonBridge() throws {
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("AIRS-C4-bound-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("synthetic.audit.json"), output = root.appendingPathComponent("projection.json")
        let log = root.appendingPathComponent("bridge.log")
        try report().write(to:source); try Data().write(to:log)
        let process = Process(), handle = try FileHandle(forWritingTo:log)
        defer { try? handle.close() }
        let candidates = [ProcessInfo.processInfo.environment["AIRS_PYTHON"],"/opt/homebrew/bin/python3","/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"].compactMap { $0 }
        process.executableURL = URL(fileURLWithPath:try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath:$0) }))
        process.arguments = ["-I","-B","-S",project.appendingPathComponent("airs_cli.py").path,"handoff","--report",source.path,"--finding-id",findingID,"--output",output.path]
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        let diagnostic = String(decoding:try Data(contentsOf:log),as:UTF8.self)
        XCTAssertEqual(process.terminationStatus,0,diagnostic)
        let native = try request()
        let object = try json(native.requestBytes)
        let expected = try json(Data(contentsOf:output))
        XCTAssertTrue(NSDictionary(dictionary:try XCTUnwrap(object["projection"] as? [String:Any])).isEqual(to:expected))
        XCTAssertEqual(try Data(contentsOf:source),report(),"Original source bytes must remain untouched")
    }
    func testLateAssociationAndDescriptorFileAdmission() async throws {
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent("AIRS-C4-bound-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let ledger = BoundReviewLedger(root:root.appendingPathComponent("ledger")), request = try request()
        let receipt = try bytes(ack(request))
        let before = try await ledger.importAcknowledgment(receipt); XCTAssertFalse(before.associated)
        try await ledger.retain(request)
        let after = try await ledger.entries(); XCTAssertTrue(try XCTUnwrap(after.first).associated)
        let file = root.appendingPathComponent("data.json"), link = root.appendingPathComponent("link.json")
        try receipt.write(to:file); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertEqual(try BoundReviewFiles.read(file,limit:1_048_576),receipt)
        XCTAssertThrowsError(try BoundReviewFiles.read(link,limit:1_048_576))
        XCTAssertThrowsError(try BoundReviewFiles.read(root,limit:1_048_576))
        XCTAssertThrowsError(try BoundReviewFiles.read(file,limit:1))
    }

}
