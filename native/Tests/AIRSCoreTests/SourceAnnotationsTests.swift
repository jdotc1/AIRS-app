import Foundation
import XCTest
@testable import AIRSCore

final class SourceAnnotationsTests: XCTestCase {
    private func original() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func enriched(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original()) as? [String: Any])
        let image = object["image"] as! [String: Any]
        let findings = object["findings"] as! [[String: Any]]
        var annotations: [String: Any] = [
            "schema_version": 1, "status": "matched", "message": "Owned test", "inline_chain": "not_evaluated", "limitations": [],
            "image_identity": Dictionary(uniqueKeysWithValues: ["architecture", "cpu_subtype", "uuid", "slice_sha256", "preferred_base", "container_sha256", "slice_offset", "slice_size"].map { ($0, image[$0]!) }),
            "attachment": ["path": "/owned/fixture.dSYM", "architecture": image["architecture"]!, "cpu_subtype": image["cpu_subtype"]!, "uuid": image["uuid"]!, "slice_sha256": String(repeating: "c", count: 64), "slice_offset": 0, "slice_size": 512],
            "functions": findings.map { finding -> [String: Any] in
                let function = finding["function"] as! [String: Any]
                return ["finding_id": finding["id"]!, "pc": function["address"]!, "status": "mapped", "name_status": "unique", "candidate_count": 1,
                        "locations": [["path": "/owned/source.c", "line": 3, "column": 5, "discriminator": 0, "source_status": "missing"]]]
            }
        ]
        edit(&annotations)
        object["source_annotations"] = annotations
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testMatchingAttachmentPreservesVerdictsAndMakesSourceExplicit() throws {
        let data = try enriched()
        let report = try ReportFiles.decodeSymbolEnrichment(original: original(), enriched: data)
        XCTAssertEqual(report.findings.map(\.verdict), [.agreement, .inconsistency, .unresolved])
        let annotations = try XCTUnwrap(report.sourceAnnotations)
        XCTAssertEqual(annotations.inlineChain, "not_evaluated")
        XCTAssertEqual(annotations.functions[0].locations[0].line, 3)
        XCTAssertEqual(annotations.functions[0].locations[0].sourceStatus, "missing")
        XCTAssertEqual(annotations.imageIdentity.sliceSHA256, report.image.sliceSHA256)
    }

    func testStaleIdentityWrongFindingAndAmbiguousCountCannotBecomeSourceLabels() throws {
        for mutation in 0..<6 {
            let data = try enriched { annotations in
                if mutation == 0 { annotations["schema_version"] = 2 }
                else if mutation == 1 {
                    var identity = annotations["image_identity"] as! [String: Any]
                    identity["slice_sha256"] = String(repeating: "d", count: 64)
                    annotations["image_identity"] = identity
                } else {
                    var functions = annotations["functions"] as! [[String: Any]]
                    if mutation == 2 { functions[0]["pc"] = "0x100001020" }
                    if mutation == 3 { functions[0]["candidate_count"] = 2 }
                    if mutation == 4 { functions[0]["finding_id"] = "absent" }
                    if mutation == 5 { functions[0]["name_status"] = "duplicate" }
                    annotations["functions"] = functions
                }
            }
            XCTAssertThrowsError(try AuditReport.decode(data))
        }
    }

    func testRejectedDSYMUsesAttachmentDiagnosticWithoutMislabelingAudit() throws {
        let data = try enriched { annotations in
            annotations["status"] = "uuid_mismatch"
            annotations["message"] = "No dSYM UUID matches the recorded image"
            annotations["attachment"] = NSNull()
            annotations["functions"] = []
        }
        XCTAssertThrowsError(try ReportFiles.decodeSymbolEnrichment(original: original(), enriched: data)) { error in
            guard case SymbolAttachmentError.rejected = error else {
                return XCTFail("Expected a source attachment diagnostic")
            }
            XCTAssertEqual(error.localizedDescription, "No dSYM UUID matches the recorded image")
        }
    }

    func testEnrichmentCannotReplaceEvidenceOrDropUnknownFields() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: enriched()) as? [String: Any])
        var findings = object["findings"] as! [[String: Any]]
        findings[0]["limitations"] = ["Changed by backend"]
        object["findings"] = findings
        let changed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ReportFiles.decodeSymbolEnrichment(original: original(), enriched: changed))
        var originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: original()) as? [String: Any])
        originalObject["future_field"] = ["keep": true]
        let withFuture = try JSONSerialization.data(withJSONObject: originalObject)
        XCTAssertThrowsError(try ReportFiles.decodeSymbolEnrichment(original: withFuture, enriched: enriched()))
    }
}
