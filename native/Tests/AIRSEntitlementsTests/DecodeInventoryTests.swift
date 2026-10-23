import Foundation
import XCTest
@testable import AIRSEntitlements

final class DecodeInventoryTests: XCTestCase {
    /// New literal schema-1 observation; does not regenerate or re-read a sealed inventory.
    func wire() -> [String:Any] {
        ["schema_version":1,"report_kind":"airs.decode_inventory","decoder_model":"owned-new-model","status":"complete","address_space":"preferred_vm",
         "analysis_config":["limits":["max_functions":2,"max_instructions_per_function":8,"max_total_instructions":8,"max_evidence_per_function":2,"max_total_evidence":2]],
         "image":["display_name":"owned","container_sha256":String(repeating:"1",count:64),"slice_sha256":String(repeating:"2",count:64),"architecture":"arm64","cpu_subtype":0,"uuid":NSNull(),"slice_offset":0,"slice_size":128,"preferred_base":"0x1000","file_type":6],
         "summary":["function_count":1,"fully_scanned_function_count":1,"observed_word_count":2,"decoder_admitted_word_count":1,"decline_count":1,"retained_blocker_count":1,"omitted_decline_count":0],
         "reasons":[["reason":"owned_refusal","observed_count":1]],
         "functions":[["function":["name":"owned","address":"0x1000","end_address":"0x1008","image_offset":"0x0","size":8,"boundary_source":"lc_function_starts"],"scan_status":"complete","word_scan_complete":true,"blockers_complete":true,"observed_word_count":2,"decoder_admitted_word_count":1,"decline_count":1,"omitted_decline_count":0,"blockers":[["address":"0x1004","word":"0xffffffff","reason":"owned_refusal","message":"Owned unmodeled word"]]]],
         "issues":[],"limitations":["Decode only; no recovery claim."]]
    }
    func decode(_ wire:[String:Any]) throws -> DecodeInventory { try DecodeInventory.decode(JSONSerialization.data(withJSONObject:wire)) }
    func testSavedCountsModelIdentityAndRefusalAreRetained() throws {
        let value=try decode(wire())
        XCTAssertEqual(value.decoder_model,"owned-new-model")
        XCTAssertEqual(value.image.slice_sha256,String(repeating:"2",count:64))
        XCTAssertEqual(value.summary.decline_count,1)
        XCTAssertEqual(value.functions[0].blockers[0].address,"0x1004")
        XCTAssertTrue(value.functions[0].word_scan_complete)
    }
    func testPartialOmittedDetailsCannotClaimComplete() throws {
        var value=wire(),rows=value["functions"] as! [[String:Any]],summary=value["summary"] as! [String:Any]
        rows[0]["blockers"]=[];rows[0]["omitted_decline_count"]=1;rows[0]["blockers_complete"]=false
        summary["retained_blocker_count"]=0;summary["omitted_decline_count"]=1
        value["functions"]=rows;value["summary"]=summary
        XCTAssertThrowsError(try decode(value))
        value["status"]="partial"
        let admitted=try decode(value)
        XCTAssertEqual(admitted.summary.omitted_decline_count,1)
        XCTAssertFalse(admitted.functions[0].blockers_complete)
    }
    func testCounterfeitCountsReasonOrPCFailAdmission() throws {
        for fault in ["summary","reason","pc","word","duplicate"] {
            var value=wire(),rows=value["functions"] as! [[String:Any]],blockers=rows[0]["blockers"] as! [[String:Any]]
            switch fault {
            case "summary":var summary=value["summary"] as! [String:Any];summary["decline_count"]=0;value["summary"]=summary
            case "reason":value["reasons"]=[["reason":"another","observed_count":1]]
            case "pc":blockers[0]["address"]="0x1008";rows[0]["blockers"]=blockers
            case "word":blockers[0]["word"]="0x100000000";rows[0]["blockers"]=blockers
            default:rows.append(rows[0])
            }
            value["functions"]=rows
            XCTAssertThrowsError(try decode(value),fault)
        }
    }
    func testWrongKindAddressSpaceDigestAndDuplicateKeysFail() throws {
        for fault in ["report_kind","address_space","digest"] {
            var value=wire()
            if fault == "digest" {var image=value["image"] as! [String:Any];image["slice_sha256"]="unknown";value["image"]=image}
            else {value[fault]="wrong"}
            XCTAssertThrowsError(try decode(value))
        }
        var text=String(decoding:try JSONSerialization.data(withJSONObject:wire()),as:UTF8.self)
        text.insert(contentsOf:"\"schema_version\":1,",at:text.index(after:text.startIndex))
        XCTAssertThrowsError(try DecodeInventory.decode(Data(text.utf8)))
    }
    func testIncompleteScanAndExcludedArchitectureRetainZeroObservations() throws {
        var value=wire(),rows=value["functions"] as! [[String:Any]],summary=value["summary"] as! [String:Any]
        rows[0]["scan_status"]="excluded_architecture";rows[0]["word_scan_complete"]=false;rows[0]["blockers_complete"]=false
        for key in ["observed_word_count","decoder_admitted_word_count","decline_count","omitted_decline_count"] {rows[0][key]=0}
        rows[0]["blockers"]=[]
        for key in ["fully_scanned_function_count","observed_word_count","decoder_admitted_word_count","decline_count","retained_blocker_count","omitted_decline_count"] {summary[key]=0}
        var image=value["image"] as! [String:Any];image["architecture"]="arm64e";image["cpu_subtype"]=2
        value["image"]=image;value["functions"]=rows;value["summary"]=summary;value["reasons"]=[];value["status"]="partial"
        XCTAssertEqual(try decode(value).summary.observed_word_count,0)
        rows[0]["word_scan_complete"]=true;value["functions"]=rows
        XCTAssertThrowsError(try decode(value))
    }
    func testInvalidExtentDiagnosticRowsRemainUnresolvedObservations() throws {
        for end in ["0x1000","0xffc"] {
            var value=wire(),rows=value["functions"] as! [[String:Any]],summary=value["summary"] as! [String:Any]
            var fn=rows[0]["function"] as! [String:Any]
            fn["end_address"]=end;fn["size"]=end == "0x1000" ? 0 : -4;rows[0]["function"]=fn
            rows[0]["scan_status"]="invalid_extent";rows[0]["word_scan_complete"]=false;rows[0]["blockers_complete"]=false
            for key in ["observed_word_count","decoder_admitted_word_count","decline_count","omitted_decline_count"] {rows[0][key]=0}
            rows[0]["blockers"]=[]
            for key in ["fully_scanned_function_count","observed_word_count","decoder_admitted_word_count","decline_count","retained_blocker_count","omitted_decline_count"] {summary[key]=0}
            value["functions"]=rows;value["summary"]=summary;value["reasons"]=[];value["status"]="partial"
            XCTAssertEqual(try decode(value).functions[0].scan_status,"invalid_extent")
            rows[0]["word_scan_complete"]=true;value["functions"]=rows
            XCTAssertThrowsError(try decode(value))
        }
    }

}
