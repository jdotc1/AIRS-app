import XCTest
import AIRSCore
@testable import AIRSEntitlements
final class CoverageInventoryTests:XCTestCase {
    var root:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/coverage")}
    func data(_ name:String)throws->Data {try Data(contentsOf:root.appendingPathComponent(name+".json"))}
    func testEmittedCountsDuplicatesAndOverlappingReasonsKeepTheirDenominators() throws {
        let single=try CoverageInventory.decode(data("single")),duplicates=try CoverageInventory.decode(data("duplicates")),overlap=try CoverageInventory.decode(data("overlap"))
        XCTAssertEqual(single.summary.function_count,9);XCTAssertEqual(single.summary.unresolved_count,4)
        XCTAssertEqual(duplicates.summary.function_count,9);XCTAssertEqual(duplicates.summary.duplicate_report_count,1)
        XCTAssertEqual(single.compatibleVerdictRatio?.functionDenominator,9);XCTAssertEqual(single.compatibleVerdictRatio?.resolvedNumerator,5)
        XCTAssertGreaterThan(overlap.reasons.reduce(0){$0+$1.count},overlap.summary.unresolved_count)
    }
    func testMixedModelsConfigurationsAndConflictsCannotMergeRatios() throws {
        for name in ["mixed-models","mixed-configs","conflicts"] {
            let value=try CoverageInventory.decode(data(name));XCTAssertNil(value.compatibleVerdictRatio);XCTAssertEqual(value.summary.function_count,18)
        }
        let conflict=try CoverageInventory.decode(data("conflicts"));XCTAssertEqual(conflict.conflicting_report_indices,[0,1]);XCTAssertEqual(conflict.summary.unique_image_model_config_count,1)
    }
    func testZeroObservationsAndPartialInputsDoNotBecomeCompleteAnalysis() throws {
        let zero=try CoverageInventory.decode(data("zero-observations"));XCTAssertEqual(zero.summary.function_count,0);XCTAssertNil(zero.compatibleVerdictRatio)
        let partial=try CoverageInventory.decode(data("partial-input"));XCTAssertEqual(partial.status,"complete");XCTAssertEqual(partial.summary.function_count,9)
        // Aggregation status cannot promise input completeness. Only source reports
        // carry issues/limits, so the UI always states that boundary.
    }
    func testSelectedSourceMustMatchModelConfigSliceAndReferencedObservation() throws {
        let inventory=try CoverageInventory.decode(data("single")),reason=try XCTUnwrap(inventory.reasons.first),example=try XCTUnwrap(reason.examples.first)
        let source=try data("source.audit"),resolved=try inventory.resolve(example,reason:reason.reason,sourceBytes:source)
        XCTAssertEqual(resolved.1.id,example.finding_id)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:source) as? [String:Any]),image=try XCTUnwrap(object["image"] as? [String:Any])
        image["slice_sha256"]=String(repeating:"0",count:64);object["image"]=image
        XCTAssertThrowsError(try inventory.resolve(example,reason:reason.reason,sourceBytes:JSONSerialization.data(withJSONObject:object)))
        var changed=try XCTUnwrap(JSONSerialization.jsonObject(with:source) as? [String:Any]),config=try XCTUnwrap(changed["analysis_config"] as? [String:Any]);config["owned-change"]=true;changed["analysis_config"]=config
        XCTAssertThrowsError(try inventory.resolve(example,reason:reason.reason,sourceBytes:JSONSerialization.data(withJSONObject:changed)))
    }
    func testMalformedTotalsDanglingExamplesAndDuplicateChainsAreRejected() throws {
        var value=try XCTUnwrap(JSONSerialization.jsonObject(with:data("single")) as? [String:Any]),summary=try XCTUnwrap(value["summary"] as? [String:Any]);summary["function_count"]=10;value["summary"]=summary
        XCTAssertThrowsError(try CoverageInventory.decode(JSONSerialization.data(withJSONObject:value)))
        value=try XCTUnwrap(JSONSerialization.jsonObject(with:data("single")) as? [String:Any]);var reasons=try XCTUnwrap(value["reasons"] as? [[String:Any]]),examples=try XCTUnwrap(reasons[0]["examples"] as? [[String:Any]]);examples[0]["report_index"]=127;reasons[0]["examples"]=examples;value["reasons"]=reasons
        XCTAssertThrowsError(try CoverageInventory.decode(JSONSerialization.data(withJSONObject:value)))
        value=try XCTUnwrap(JSONSerialization.jsonObject(with:data("duplicates")) as? [String:Any]);var reports=try XCTUnwrap(value["reports"] as? [[String:Any]]);reports[1]["duplicate_of"]=1;value["reports"]=reports
        XCTAssertThrowsError(try CoverageInventory.decode(JSONSerialization.data(withJSONObject:value)))
    }
}

final class CoverageConfigurationTests:XCTestCase {
    func testPythonDistinctUnicodeAndNumericConfigurationsRemainDistinct() throws {
        let helper=CoverageInventoryTests()
        for name in ["unicode-configs","numeric-configs"] {
            let value=try CoverageInventory.decode(helper.data(name));XCTAssertEqual(value.summary.unique_image_model_config_count,2);XCTAssertNil(value.compatibleVerdictRatio)
        }
    }
    func testSelectedSourceRejectsCanonicalEquivalentButDifferentConfiguration() throws {
        let helper=CoverageInventoryTests(),inventory=try CoverageInventory.decode(helper.data("unicode-single")),reason=try XCTUnwrap(inventory.reasons.first),example=try XCTUnwrap(reason.examples.first)
        let source=try helper.data("unicode-source.audit")
        _=try inventory.resolve(example,reason:reason.reason,sourceBytes:source)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:source) as? [String:Any]),config=try XCTUnwrap(object["analysis_config"] as? [String:Any]);config["metadata"]="e\u{301}";object["analysis_config"]=config
        XCTAssertThrowsError(try inventory.resolve(example,reason:reason.reason,sourceBytes:JSONSerialization.data(withJSONObject:object)))
    }
}

final class CoverageExactKeyTests:XCTestCase {
    func testCanonicalEquivalentConfigurationObjectKeysStayDistinct() throws {
        let helper=CoverageInventoryTests(),base=String(decoding:try helper.data("single"),as:UTF8.self)
        // Additional config fields are legal. The exact identity parser keeps
        // both Unicode spellings, even though Swift Dictionary cannot do so.
        let changed=base.replacingOccurrences(of:"\"analysis_config\": {",with:"\"analysis_config\": {\"é\": 1, \"e\\u0301\": 2,")
        let inventory=try CoverageInventory.decode(Data(changed.utf8))
        XCTAssertNotNil(inventory.compatibleVerdictRatio)
        let source=String(decoding:try helper.data("source.audit"),as:UTF8.self).replacingOccurrences(of:"\"analysis_config\": {",with:"\"analysis_config\": {\"é\": 1, \"e\\u0301\": 2,")
        let reason=try XCTUnwrap(inventory.reasons.first),example=try XCTUnwrap(reason.examples.first)
        _=try inventory.resolve(example,reason:reason.reason,sourceBytes:Data(source.utf8))
        let wrong=source.replacingOccurrences(of:"\"e\\u0301\": 2,",with:"")
        XCTAssertThrowsError(try inventory.resolve(example,reason:reason.reason,sourceBytes:Data(wrong.utf8)))
    }
}

final class CoverageInputBudgetTests:XCTestCase {
    func testDuplicateReportsStillConsumeTheEmittersInputFindingBudget() throws {
        let helper=CoverageInventoryTests()
        var root=try XCTUnwrap(JSONSerialization.jsonObject(with:helper.data("single")) as? [String:Any])
        var records=try XCTUnwrap(root["reports"] as? [[String:Any]])
        var record=records[0]
        record["summary"]=["function_count":50_000,"agreement_count":50_000,"inconsistency_count":0,"unresolved_count":0,"metadata_entry_count":0,"checked_pc_count":0]
        records=(0..<5).map {index in var r=record;r["index"]=index;r["duplicate_of"]=index == 0 ? NSNull():0;return r}
        root["reports"]=records;root["reasons"]=[]
        root["summary"]=["input_report_count":5,"duplicate_report_count":4,"function_count":50_000,"agreement_count":50_000,"inconsistency_count":0,"unresolved_count":0,"unique_image_model_config_count":1,"conflicting_report_count":0]
        XCTAssertThrowsError(try CoverageInventory.decode(JSONSerialization.data(withJSONObject:root)))
    }
}
