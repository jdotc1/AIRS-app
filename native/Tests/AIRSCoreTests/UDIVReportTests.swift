import Foundation
import XCTest
@testable import AIRSCore

final class UDIVReportTests:XCTestCase {
    private func object() throws -> [String:Any] {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"udiv-v34",withExtension:"json",subdirectory:"Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    }
    private func decode(_ object:[String:Any]) throws -> AuditReport {
        try AuditReport.decode(JSONSerialization.data(withJSONObject:object))
    }
    func testV34EmittedWitnessPreservesModelScopeAndPCs() throws {
        let report=try decode(object())
        XCTAssertEqual(report.generator.analysisModelVersion,"arm64-bounded-udiv-v34")
        XCTAssertEqual(report.summary.functionCount,1)
        XCTAssertEqual(report.findings.first?.verdict,.agreement)
        XCTAssertEqual(report.findings.first?.scope,"modeled_leaf_body")
        XCTAssertEqual(report.findings.first?.checkedPCs,["0x1000"])
    }
    func testV34KnownAdmissionAndFutureLabelControl() throws {
        for fault in ["subtype","boundary","scope","recovery"] {
            var wire=try object(),image=wire["image"] as! [String:Any],findings=wire["findings"] as! [[String:Any]]
            switch fault {
            case "subtype":image["cpu_subtype"]=0x80000000
            case "boundary":var function=findings[0]["function"] as! [String:Any];function["boundary_source"]="compact_unwind";findings[0]["function"]=function
            case "scope":findings[0]["scope"]="synchronous_call_sites"
            default:findings[0]["encoding"]="0x02000100"
            }
            wire["image"]=image;wire["findings"]=findings
            XCTAssertThrowsError(try decode(wire),fault)
        }
        var wire=try object(),image=wire["image"] as! [String:Any],generator=wire["generator"] as! [String:Any]
        image["cpu_subtype"]=0x80000000;wire["image"]=image
        generator["analysis_model_version"]="arm64-bounded-udiv-v34-future";wire["generator"]=generator
        XCTAssertNoThrow(try decode(wire))
        generator["analysis_model_version"]="arm64-bounded-clz-v32";wire["generator"]=generator
        XCTAssertThrowsError(try decode(wire))
    }
    func testV34DWARFAdmissionRequiresEvaluatedCoverageAndEncoding() throws {
        var wire=try object(),findings=wire["findings"] as! [[String:Any]]
        findings[0]["mode"]="dwarf";findings[0]["coverage"]="dwarf_evaluated"
        findings[0]["scope"]="synchronous_call_sites";findings[0]["encoding"]="0x03000004"
        wire["findings"]=findings
        XCTAssertNoThrow(try decode(wire))
        findings[0]["coverage"]="dwarf_reference";wire["findings"]=findings
        XCTAssertThrowsError(try decode(wire))
        findings[0]["coverage"]="dwarf_evaluated";findings[0]["encoding"]="0x02000000";wire["findings"]=findings
        XCTAssertThrowsError(try decode(wire))
    }
}
