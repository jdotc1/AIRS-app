import Foundation
import XCTest
@testable import AIRSCore

final class CFIControlModelAdmissionTests: XCTestCase {
    private func object(_ name: String = "cfi-control-v41") throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> AuditReport {
        try AuditReport.decode(JSONSerialization.data(withJSONObject: value))
    }
    func testEmittedV41WitnessPreservesModelAndExactCheckedPC() throws {
        let report = try decode(object())
        XCTAssertEqual(report.generator.analysisModelVersion, "arm64-bounded-cfi-control-v41")
        XCTAssertEqual(report.summary.functionCount, 1)
        XCTAssertEqual(report.findings.first?.verdict, .agreement)
        XCTAssertEqual(report.findings.first?.coverage, "dwarf_evaluated")
        XCTAssertEqual(report.findings.first?.scope, "synchronous_call_sites")
        XCTAssertEqual(report.findings.first?.checkedPCs, ["0x10000100c"])
    }
    func testV40AndAlternateHistoricalV36RemainKnownWithoutRelabeling() throws {
        let historical = try decode(object("cfi-control-v36"))
        XCTAssertEqual(historical.generator.analysisModelVersion, "arm64-bounded-cfi-control-v36")
        let oldURL = try XCTUnwrap(Bundle.module.url(forResource: "equivalent-compact-v39", withExtension: "json", subdirectory: "Fixtures"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: oldURL)) as? [String: Any])
        var generator = old["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-local-fde-v40"; old["generator"] = generator
        XCTAssertEqual(try decode(old).generator.analysisModelVersion, "arm64-bounded-local-fde-v40")
    }
    func testKnownCFIModelsEnforceAdmissionAndFutureLabelsStayDistinct() throws {
        for model in ["arm64-bounded-cfi-control-v41", "arm64-bounded-local-fde-v40", "arm64-bounded-cfi-control-v36"] {
            for fault in ["subtype", "boundary", "scope", "coverage", "encoding"] {
                var wire = try object(), generator = wire["generator"] as! [String: Any]
                var image = wire["image"] as! [String: Any], findings = wire["findings"] as! [[String: Any]]
                generator["analysis_model_version"] = model
                switch fault {
                case "subtype": image["cpu_subtype"] = 0x80000000
                case "boundary": var function = findings[0]["function"] as! [String: Any]; function["boundary_source"] = "compact_unwind"; findings[0]["function"] = function
                case "scope": findings[0]["scope"] = "metadata_only"
                case "coverage": findings[0]["coverage"] = "dwarf_reference"
                default: findings[0]["encoding"] = "0x04000000"
                }
                wire["generator"] = generator; wire["image"] = image; wire["findings"] = findings
                XCTAssertThrowsError(try decode(wire), "\(model): \(fault)")
            }
        }
        var future = try object(), generator = future["generator"] as! [String: Any], image = future["image"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-cfi-control-v41-future"; image["cpu_subtype"] = 0x80000000
        future["generator"] = generator; future["image"] = image
        XCTAssertNoThrow(try decode(future))
    }
}
