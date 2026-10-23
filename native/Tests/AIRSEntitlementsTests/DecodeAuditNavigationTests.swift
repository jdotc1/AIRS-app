import Foundation
import XCTest
@testable import AIRSEntitlements

final class DecodeAuditNavigationTests:XCTestCase {
    func report() throws -> [String:Any] {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("AIRSCoreTests/Fixtures/audit-v1.json"))) as? [String:Any])
    }
    func bytes(_ value:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:value)}
    func inventory(_ report:[String:Any]) throws -> DecodeInventory {
        var image=try XCTUnwrap(report["image"] as? [String:Any]);image["file_type"]=2
        let finding=try XCTUnwrap((report["findings"] as? [[String:Any]])?.first)
        let function=try XCTUnwrap(finding["function"] as? [String:Any])
        let model=try XCTUnwrap((report["generator"] as? [String:Any])?["analysis_model_version"] as? String)
        let wire:[String:Any] = ["schema_version":1,"report_kind":"airs.decode_inventory","decoder_model":model,"status":"partial","address_space":"preferred_vm","image":image,
            "analysis_config":["limits":["max_functions":1,"max_instructions_per_function":0,"max_total_instructions":0,"max_evidence_per_function":0,"max_total_evidence":0]],
            "functions":[["function":function,"scan_status":"partial_total_budget","word_scan_complete":false,"blockers_complete":false,"observed_word_count":0,"decoder_admitted_word_count":0,"decline_count":0,"omitted_decline_count":0,"blockers":[]]],
            "summary":["function_count":1,"fully_scanned_function_count":0,"observed_word_count":0,"decoder_admitted_word_count":0,"decline_count":0,"retained_blocker_count":0,"omitted_decline_count":0],"reasons":[],"issues":[],"limitations":["New saved-navigation test; decode and audit budgets are independent."]]
        return try DecodeInventory.decode(bytes(wire))
    }
    func testExactSavedImageAndFunctionNavigateWithoutConfigEquivalence() throws {
        let wire=try report(),inventory=try inventory(wire),row=try XCTUnwrap(inventory.functions.first)
        let resolved=try inventory.resolveFunction(row.id,sourceBytes:bytes(wire))
        XCTAssertEqual(resolved.1.function.address,row.function.address)
        XCTAssertEqual(resolved.0.summary.functionCount,3)
        XCTAssertEqual(resolved.1.checkedPCs,["0x10000100c"])
        XCTAssertEqual(inventory.summary.observed_word_count,0)
    }
    func testEachRecordedIdentityMismatchDeclines() throws {
        let wire=try report(),inventory=try inventory(wire),row=try XCTUnwrap(inventory.functions.first)
        for key in ["container_sha256","slice_sha256","slice_offset","slice_size","uuid","preferred_base","cpu_subtype","architecture","file_type"] {
            var changed=wire,image=wire["image"] as! [String:Any]
            switch key {
            case "container_sha256","slice_sha256":image[key]=String(repeating:"c",count:64)
            case "slice_offset":image[key]=16
            case "slice_size":image[key]=16384
            case "uuid":image[key]=NSNull()
            case "preferred_base":image[key]="0x0"
            case "cpu_subtype":image[key]=1
            case "file_type":image[key]="bundle"
            default:image[key]="arm64e"
            }
            changed["image"]=image
            XCTAssertThrowsError(try inventory.resolveFunction(row.id,sourceBytes:bytes(changed)),key)
        }
    }
    func testWrongModelAndUnlistedFunctionDecline() throws {
        let wire=try report(),inventory=try inventory(wire),row=try XCTUnwrap(inventory.functions.first)
        var changed=wire,generator=wire["generator"] as! [String:Any]
        generator["analysis_model_version"]="future-different-model";changed["generator"]=generator
        XCTAssertThrowsError(try inventory.resolveFunction(row.id,sourceBytes:bytes(changed)))
        XCTAssertThrowsError(try inventory.resolveFunction("0x100001020",sourceBytes:bytes(wire)))
    }
    func testExactFunctionNameBoundaryAndExtentAreRequired() throws {
        let wire=try report(),inventory=try inventory(wire),row=try XCTUnwrap(inventory.functions.first)
        for key in ["name","boundary_source","end_address"] {
            var changed=wire,findings=wire["findings"] as! [[String:Any]],fn=(wire["findings"] as! [[String:Any]])[0]["function"] as! [String:Any]
            fn[key]=key == "name" ? "renamed" : key == "boundary_source" ? "symbol_table" : "0x10000101c"
            if key == "end_address" {fn["size"]=28}
            findings[0]["function"]=fn;changed["findings"]=findings
            XCTAssertThrowsError(try inventory.resolveFunction(row.id,sourceBytes:bytes(changed)),key)
        }
    }
}
