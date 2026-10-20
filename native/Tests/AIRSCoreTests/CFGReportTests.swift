import Foundation
import XCTest
@testable import AIRSCore

final class CFGReportTests: XCTestCase {
    private func object() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var generator = object["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-cfg-v3"
        object["generator"] = generator
        var findings = object["findings"] as! [[String: Any]]
        findings[0]["mode"] = "frameless"
        findings[0]["scope"] = "modeled_leaf_body"
        findings[0]["encoding"] = "0x02000000"
        findings[0]["evidence"] = [["code": "cfg_paths_checked", "message": "2 conservative paths checked"]]
        object["findings"] = findings
        return object
    }

    func testV3PreservesLeafScopeAndPathEvidence() throws {
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: object()))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].coverage, "compact")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_paths_checked")
    }

    func testV3RejectsFrameScopeSavedPairsAndNonexactSubtype() throws {
        for mutation in 0..<3 {
            var object = try object()
            var findings = object["findings"] as! [[String: Any]]
            if mutation == 0 { findings[0]["scope"] = "synchronous_call_sites" }
            if mutation == 1 { findings[0]["encoding"] = "0x02000001" }
            if mutation == 2 {
                var image = object["image"] as! [String: Any]
                image["cpu_subtype"] = 0x01000000
                object["image"] = image
            }
            object["findings"] = findings
            XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: object)), "Mutation \(mutation)")
        }
    }

    func testV3RetainsEvaluatedCFIRelationships() throws {
        var object = try object()
        var findings = object["findings"] as! [[String: Any]]
        findings[0]["coverage"] = "dwarf_evaluated"
        findings[0]["mode"] = "dwarf"
        findings[0]["encoding"] = "0x03000014"
        object["findings"] = findings
        XCTAssertNoThrow(try AuditReport.decode(JSONSerialization.data(withJSONObject: object)))
        findings[0]["coverage"] = "dwarf_reference"
        object["findings"] = findings
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testV4FrameCallsPreserveScopeAndRejectContradictions() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-calls-v4"
        item["generator"] = generator
        var findings = item["findings"] as! [[String: Any]]
        findings[0]["mode"] = "frame"
        findings[0]["scope"] = "synchronous_call_sites"
        findings[0]["encoding"] = "0x04000000"
        findings[0]["evidence"] = [["code": "cfg_call_site", "message": "BL observed after LR write"]]
        item["findings"] = findings
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "synchronous_call_sites")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_call_site")
        for mutation in 0..<4 {
            var invalid = item
            var rows = findings
            if mutation == 0 { rows[0]["scope"] = "modeled_leaf_body" }
            if mutation == 1 { rows[0]["encoding"] = "0x04000100" }
            if mutation == 2 { rows[0]["coverage"] = "dwarf_reference" }
            if mutation == 3 {
                var image = invalid["image"] as! [String: Any]
                image["cpu_subtype"] = 0x01000000
                invalid["image"] = image
            }
            invalid["findings"] = rows
            XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
    }

    func testV6RetainsReturnEvidenceAndEnforcesScope() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-returns-v6"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_returns_checked", "message": "Two return terminals restored caller identities"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_returns_checked")
        rows[0]["scope"] = "synchronous_call_sites"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV7DifferingTeardownsRetainScopeAndRejectSavedPairLeaf() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-teardowns-v7"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_returns_checked", "message": "2 distinct contiguous teardown sequences"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_returns_checked")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV8SharedSuffixEvidencePreservesScopeAndExactSubtype() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-suffixes-v8"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_shared_teardown", "message": "Incoming states retained separately"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_shared_teardown")
        var image = item["image"] as! [String: Any]
        image["cpu_subtype"] = 0x01000000
        item["image"] = image
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV9ConditionalEvidenceRetainsLeafScopeAndRejectsCallScope() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-conditional-v9"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Both successors are recognized teardown paths"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["scope"] = "synchronous_call_sites"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV10ConditionModelRetainsEvidenceAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-conditions-v10"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "EQ through LE conditions retain separate states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV11FlagModelRetainsEvidenceAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-flags-v11"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Immediate W and X flags retain separate states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV12RegisterFlagsRetainEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-register-flags-v12"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Unshifted register flags retain conservative path states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV13ShiftedFlagsRetainEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-shifted-flags-v13"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Shifted register flags retain conservative path states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV14ExtendedFlagsRetainEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-extended-flags-v14"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Extended register flags retain conservative path states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV15LogicalFlagsRetainEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-logical-flags-v15"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Logical register flags retain conservative path states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV16LogicalImmediateRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-logical-immediate-v16"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Logical immediate flags retain conservative path states"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV17NonflagImmediateRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-nonflag-immediate-v17"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Nonflag immediate effects preserve comparison flags"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV18NonflagRegisterRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-nonflag-register-v18"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Nonflag register effects preserve comparison flags"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV19CarryRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-carry-v19"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Carry effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV20ConditionalCompareRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-conditional-compare-v20"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Conditional compare retains bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV21ConditionalSelectRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-conditional-select-v21"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Conditional select retains bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV22BitfieldRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-bitfield-v22"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Bitfield effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV23ExtractRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-extract-v23"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "EXTR effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV24VariableShiftRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-variable-shift-v24"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Variable shifts retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV25MultiplyRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-multiply-v25"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Multiply effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV26WideningMultiplyRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-widening-multiply-v26"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "Widening multiply effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV27HighMultiplyRetainsEvidenceScopeAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-high-multiply-v27"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_conditional_teardown", "message": "High multiply effects retain bounded recovery evidence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_conditional_teardown")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV28LoopRetainsScopeEvidenceAndEncodingBoundary() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-loops-v28"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_loop_checked", "message": "Exact recurrent state closes safety exploration; no termination claim"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_loop_checked")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV29LoopCallRetainsSynchronousScopeAndEvidence() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-loop-calls-v29"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["scope"] = "synchronous_call_sites"
        rows[0]["mode"] = "frame"
        rows[0]["encoding"] = "0x04000000"
        rows[0]["evidence"] = [["code": "cfg_loop_checked", "message": "Direct call in one natural loop"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "synchronous_call_sites")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_loop_checked")
    }

    func testV30CFARegisterRetainsEvaluatedScopeAndEvidence() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-cfa-register-v30"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["scope"] = "synchronous_call_sites"
        rows[0]["mode"] = "dwarf"
        rows[0]["coverage"] = "dwarf_evaluated"
        rows[0]["encoding"] = "0x03000014"
        rows[0]["evidence"] = [["code": "dwarf_cfi_row", "message": "CFA register changes to x29 at the BL PC"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "synchronous_call_sites")
        XCTAssertEqual(report.findings[0].coverage, "dwarf_evaluated")
        XCTAssertEqual(report.findings[0].evidence[0].code, "dwarf_cfi_row")
    }

    func testV31SequentialLoopsRetainLeafScopeAndEvidence() throws {
        var item = try object()
        var generator = item["generator"] as! [String: Any]
        generator["analysis_model_version"] = "arm64-bounded-sequential-loops-v31"
        item["generator"] = generator
        var rows = item["findings"] as! [[String: Any]]
        rows[0]["evidence"] = [["code": "cfg_loop_checked", "message": "Two disjoint natural loops checked with exact state recurrence"]]
        item["findings"] = rows
        let report = try AuditReport.decode(JSONSerialization.data(withJSONObject: item))
        XCTAssertEqual(report.findings[0].scope, "modeled_leaf_body")
        XCTAssertEqual(report.findings[0].evidence[0].code, "cfg_loop_checked")
        rows[0]["encoding"] = "0x02000001"
        item["findings"] = rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject: item)))
    }

    func testV32CLZRetainsScopeAndRejectsInvalidSupportedEncoding() throws {
        var item=try object()
        var generator=try XCTUnwrap(item["generator"] as? [String:Any])
        generator["analysis_model_version"]="arm64-bounded-clz-v32";item["generator"]=generator
        var rows=try XCTUnwrap(item["findings"] as? [[String:Any]])
        rows[0]["evidence"]=[["code":"cfg_paths_checked","message":"Scalar CLZ preserved caller state; no all-PC claim"]]
        item["findings"]=rows
        let report=try AuditReport.decode(JSONSerialization.data(withJSONObject:item))
        XCTAssertEqual(report.generator.analysisModelVersion,"arm64-bounded-clz-v32")
        XCTAssertEqual(report.findings[0].scope,"modeled_leaf_body")
        rows[0]["encoding"]="0x02000001";item["findings"]=rows
        XCTAssertThrowsError(try AuditReport.decode(JSONSerialization.data(withJSONObject:item)))
    }

}
