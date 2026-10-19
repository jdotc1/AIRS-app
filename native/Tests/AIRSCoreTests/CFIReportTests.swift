import Foundation
import XCTest
@testable import AIRSCore

final class CFIReportTests: XCTestCase {
    private func object() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var generator = object["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-linear-dwarf-v2"
        object["generator"] = generator
        var findings = object["findings"] as! [[String: Any]]
        findings[0]["coverage"] = "dwarf_evaluated"
        findings[0]["mode"] = "dwarf"
        findings[0]["encoding"] = "0x03000014"
        object["findings"] = findings
        return object
    }

    func testV2SupportsEvaluatedCFIWithExistingModeledScope() throws {
        let data = try JSONSerialization.data(withJSONObject: object())
        let report = try AuditReport.decode(data)
        XCTAssertEqual(report.findings[0].coverage, "dwarf_evaluated")
        XCTAssertEqual(report.findings[0].verdict, .agreement)
        XCTAssertEqual(report.findings[0].scope, "synchronous_call_sites")
    }

    func testV2RejectsReferenceOnlyWrongModeBoundaryAndSubtype() throws {
        for mutation in 0..<6 {
            var object = try object()
            var findings = object["findings"] as! [[String: Any]]
            if mutation == 0 { findings[0]["coverage"] = "dwarf_reference" }
            if mutation == 1 { findings[0]["mode"] = "frame" }
            if mutation == 2 { findings[0]["encoding"] = "0x04000000" }
            if mutation == 3 {
                var function = findings[0]["function"] as! [String: Any]
                function["boundary_source"] = "symbol_table"
                findings[0]["function"] = function
            }
            if mutation == 4 {
                var image = object["image"] as! [String: Any]
                image["cpu_subtype"] = 0x80000000
                object["image"] = image
            }
            if mutation == 5 { findings[0]["scope"] = "metadata_only" }
            object["findings"] = findings
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try AuditReport.decode(data), "Mutation \(mutation)")
        }
    }

    func testHistoricalModelCannotClaimEvaluatedCFI() throws {
        var object = try object()
        var generator = object["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-linear-v1"
        object["generator"] = generator
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testV5CFICallsRetainRowsAndRejectReferenceOrWrongBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-dwarf-cfg-v5"
        item["generator"] = generator
        var findings = item["findings"] as! [[String: Any]]
        findings[0]["evidence"] = [["code": "dwarf_cfi_row", "message": "Row selected at BL PC"], ["code": "cfg_call_site", "message": "After LR write"]]
        item["findings"] = findings
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "synchronous_call_sites")
        XCTAssertEqual(report.findings[0].evidence[0].code, "dwarf_cfi_row")
        for mutation in 0..<3 {
            var invalid = item
            var rows = findings
            if mutation == 0 { rows[0]["coverage"] = "dwarf_reference" }
            if mutation == 1 { rows[0]["encoding"] = "0x04000000" }
            if mutation == 2 {
                var function = rows[0]["function"] as! [String: Any]
                function["boundary_source"] = "symbol_table"
                rows[0]["function"] = function
            }
            invalid["findings"] = rows
            XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
    }

}
