import Foundation
import XCTest
@testable import AIRSCore

final class AuditReportTests: XCTestCase {
    private func fixture(_ name: String = "audit-v1") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func changedFixture(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func changedFinding(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        try changedFixture { object in
            var findings = object["findings"] as! [[String: Any]]
            edit(&findings[0])
            object["findings"] = findings
        }
    }

    func testV1FixtureKeepsVerdictCoverageScopeAndEvidenceDistinct() throws {
        let report = try AuditReport.decode(fixture())
        XCTAssertEqual(report.image.architecture, "arm64")
        XCTAssertEqual(report.summary.functionCount, 3)
        XCTAssertEqual(report.summary.checkedPCCount, 2)
        XCTAssertEqual(report.findings.map(\.verdict), [.agreement, .inconsistency, .unresolved])
        let discrepancy = report.findings[1]
        XCTAssertEqual(discrepancy.coverage, "compact")
        XCTAssertEqual(discrepancy.scope, "synchronous_call_sites")
        XCTAssertEqual(discrepancy.checkedPCs, ["0x100001038"])
        XCTAssertEqual(discrepancy.evidence[0].expected?.displayText, "original x30")
        XCTAssertEqual(discrepancy.evidence[0].observed?.displayText, "overwritten x30")
        XCTAssertEqual(report.findings[2].verdict.title, "Unresolved")
        XCTAssertTrue(report.findings[2].checkedPCs.isEmpty)
    }

    func testUnknownMajorSchemaFailsBeforeV1PayloadDecoding() throws {
        let data = Data(#"{"schema_version":2,"report_kind":"airs.audit"}"#.utf8)
        XCTAssertThrowsError(try AuditReport.decode(data)) { error in
            guard case ReportError.unsupportedSchema(2) = error else {
                return XCTFail("Expected an explicit unsupported-schema error, got \(error)")
            }
        }
    }

    func testSummaryMismatchCannotBecomeDisplayedCoverage() throws {
        let data = try changedFixture { object in
            var summary = object["summary"] as! [String: Any]
            summary["agreement_count"] = 3
            object["summary"] = summary
        }
        XCTAssertThrowsError(try AuditReport.decode(data))
    }

    func testAgreementWithoutAReportedPCIsRejected() throws {
        let data = try changedFixture { object in
            var findings = object["findings"] as! [[String: Any]]
            findings[0]["checked_pcs"] = []
            object["findings"] = findings
            var summary = object["summary"] as! [String: Any]
            summary["checked_pc_count"] = 1
            object["summary"] = summary
        }
        XCTAssertThrowsError(try AuditReport.decode(data))
    }

    func testEveryModelRejectsSupportedVerdictsWithoutMetadataCoverage() throws {
        for model in ["arm64-linear-v1", "future-model-for-comparison"] {
            for index in [0, 1] { // Exercise both agreement and inconsistency.
                for coverage in ["none", "unavailable"] {
                    let data = try changedFixture { object in
                        var generator = object["generator"] as! [String: Any]
                        generator["analysis_model_version"] = model
                        object["generator"] = generator
                        var findings = object["findings"] as! [[String: Any]]
                        findings[index]["coverage"] = coverage
                        object["findings"] = findings
                    }
                    XCTAssertThrowsError(try AuditReport.decode(data),
                                         "Accepted unsupported coverage \(coverage), model \(model), finding \(index)")
                }
            }
        }
    }

    func testKnownModelRejectsARM64eAndNonordinarySubtypes() throws {
        let identities: [(String, Int)] = [("arm64e", 2), ("arm64", 2),
                                            ("arm64", 0x8000_0002), ("arm64", 3)]
        for (architecture, subtype) in identities {
            let data = try changedFixture { object in
                var image = object["image"] as! [String: Any]
                image["architecture"] = architecture
                image["cpu_subtype"] = subtype
                object["image"] = image
            }
            XCTAssertThrowsError(try AuditReport.decode(data),
                                 "Accepted \(architecture) subtype \(subtype) under arm64-linear-v1")
        }
    }

    func testUnknownModelStillRequiresNonzeroEncodingForSupportedCompactCoverage() throws {
        for index in [0, 1] { // Both agreement and inconsistency need the rule.
            for encoding in [nil, "0x0", "0x100000000"] as [String?] {
                let data = try changedFixture { object in
                    var generator = object["generator"] as! [String: Any]
                    generator["analysis_model_version"] = "future-model-for-comparison"
                    object["generator"] = generator
                    var findings = object["findings"] as! [[String: Any]]
                    if let encoding {
                        findings[index]["encoding"] = encoding
                    } else {
                        findings[index].removeValue(forKey: "encoding")
                    }
                    object["findings"] = findings
                }
                XCTAssertThrowsError(try AuditReport.decode(data),
                                     "Accepted unsupported compact encoding \(encoding ?? "missing") for finding \(index)")
            }
        }
    }

    func testKnownModelUsesLow24BitsForOrdinarySubtypeIdentity() throws {
        for subtype in [0, 1, 0x8000_0000, 0x8000_0001] {
            let data = try changedFixture { object in
                var image = object["image"] as! [String: Any]
                image["cpu_subtype"] = subtype
                object["image"] = image
            }
            XCTAssertEqual(try AuditReport.decode(data).image.cpuSubtype, subtype)
        }
    }

    func testKnownModelRejectsDwarfCoverageAndUntrustedBoundaries() throws {
        let dwarf = try changedFinding { finding in finding["coverage"] = "dwarf_reference" }
        XCTAssertThrowsError(try AuditReport.decode(dwarf))
        for source in ["symbol_table", "lc_function_starts_with_embedded_data", "lc_function_starts_with_relocations"] {
            let data = try changedFinding { finding in
                var function = finding["function"] as! [String: Any]
                function["boundary_source"] = source
                finding["function"] = function
            }
            XCTAssertThrowsError(try AuditReport.decode(data), "Accepted boundary source \(source)")
        }
    }

    func testKnownModelRequiresAReportedNonzeroEncoding() throws {
        let absent = try changedFinding { finding in _ = finding.removeValue(forKey: "encoding") }
        let null = try changedFinding { finding in finding["encoding"] = NSNull() }
        let zero = try changedFinding { finding in finding["encoding"] = "0x0" }
        for data in [absent, null, zero] { XCTAssertThrowsError(try AuditReport.decode(data)) }
    }

    func testKnownModelRequiresDecodedModeAndObservationScopeToAgree() throws {
        let cases: [(String, String, String)] = [
            ("0x4000000", "frame", "modeled_leaf_body"),
            ("0x2002000", "frameless", "synchronous_call_sites"),
            ("0x4000000", "frameless", "modeled_leaf_body"),
            ("0x2002000", "frame", "synchronous_call_sites"),
            ("0x3000001", "dwarf", "synchronous_call_sites"),
            ("0x5000000", "pauth_frame", "synchronous_call_sites")
        ]
        for (encoding, mode, scope) in cases {
            let data = try changedFinding { finding in
                finding["encoding"] = encoding
                finding["mode"] = mode
                finding["scope"] = scope
            }
            XCTAssertThrowsError(try AuditReport.decode(data), "Accepted \(encoding), \(mode), \(scope)")
        }
    }

    func testKnownModelRejectsSIMDReservedAndFramelessSavedPairBits() throws {
        let frameEncodings = ["0x4000100", "0x4000020", "0x4001000"]
        for encoding in frameEncodings {
            let data = try changedFinding { finding in finding["encoding"] = encoding }
            XCTAssertThrowsError(try AuditReport.decode(data), "Accepted frame encoding \(encoding)")
        }
        for encoding in ["0x2002001", "0x2002100", "0x2002020"] {
            let data = try changedFinding { finding in
                finding["encoding"] = encoding
                finding["mode"] = "frameless"
                finding["scope"] = "modeled_leaf_body"
            }
            XCTAssertThrowsError(try AuditReport.decode(data), "Accepted frameless encoding \(encoding)")
        }
    }

    func testKnownModelAcceptsStructurallySupportedFrameAndLeafRelationships() throws {
        // Import validation checks relationships; it does not authenticate the analysis.
        let frame = try changedFinding { finding in finding["encoding"] = "0x400001f" }
        XCTAssertEqual(try AuditReport.decode(frame).findings[0].mode, "frame")
        let leaf = try changedFinding { finding in
            finding["encoding"] = "0x2002000"
            finding["mode"] = "frameless"
            finding["scope"] = "modeled_leaf_body"
        }
        XCTAssertEqual(try AuditReport.decode(leaf).findings[0].scope, "modeled_leaf_body")
    }

    func testUnknownModelRemainsImportableWithMetadataPresent() throws {
        let data = try changedFixture { object in
            var generator = object["generator"] as! [String: Any]
            generator["analysis_model_version"] = "future-model-for-comparison"
            object["generator"] = generator
            var image = object["image"] as! [String: Any]
            image["architecture"] = "arm64e"
            image["cpu_subtype"] = 2
            object["image"] = image
            var findings = object["findings"] as! [[String: Any]]
            findings[0]["coverage"] = "dwarf_reference"
            findings[0]["mode"] = "dwarf"
            findings[0].removeValue(forKey: "encoding")
            object["findings"] = findings
        }
        let report = try AuditReport.decode(data)
        XCTAssertEqual(report.generator.analysisModelVersion, "future-model-for-comparison")
        XCTAssertEqual(report.findings[0].coverage, "dwarf_reference")
        XCTAssertEqual(report.image.architecture, "arm64e")
    }

    func testPCOutsideFunctionIsRejected() throws {
        let data = try changedFixture { object in
            var findings = object["findings"] as! [[String: Any]]
            findings[0]["checked_pcs"] = ["0x100002000"]
            object["findings"] = findings
        }
        XCTAssertThrowsError(try AuditReport.decode(data))
    }

    func testAdditiveV1FieldsRemainImportable() throws {
        let data = try changedFixture { object in
            object["future_display_hint"] = ["optional": true]
        }
        XCTAssertEqual(try AuditReport.decode(data).summary.functionCount, 3)
    }

    func testNonstringV1EvidenceIsRejectedBeforeBackendHandoff() throws {
        let data = try changedFixture { object in
            var findings = object["findings"] as! [[String: Any]]
            var evidence = findings[0]["evidence"] as! [[String: Any]]
            evidence[0]["observed"] = 42
            findings[0]["evidence"] = evidence
            object["findings"] = findings
        }
        XCTAssertThrowsError(try AuditReport.decode(data))
    }

    func testSearchMatchesNameAddressAndEvidence() throws {
        let report = try AuditReport.decode(fixture())
        let discrepancy = report.findings[1]
        XCTAssertTrue(discrepancy.matches("MISMATCH"))
        XCTAssertTrue(discrepancy.matches("0x100001020"))
        XCTAssertTrue(discrepancy.matches("saved return address"))
        XCTAssertFalse(discrepancy.matches("no-such-function"))
    }

    func testBoundedReadRejectsOversizedRegularFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x61, count: 17).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ReportFiles.readBounded(url, limit: 16)) { error in
            guard case ReportError.tooLarge(16) = error else {
                return XCTFail("Expected the bounded-read error, got \(error)")
            }
        }
    }

    func testEngineGeneratedComparisonFixtureDecodes() throws {
        let comparison = try ComparisonReport.decode(fixture("comparison-v1"))
        XCTAssertTrue(comparison.comparison.sameImage)
        XCTAssertTrue(comparison.comparison.modelCompatible)
        XCTAssertEqual(comparison.summary.matchedCount, 3)
        XCTAssertEqual(comparison.summary.changedCount, 1)
        XCTAssertEqual(comparison.summary.unchangedCount, 2)
        let change = try XCTUnwrap(comparison.changes.first { $0.change == "changed" })
        XCTAssertEqual(change.beforeVerdict, .inconsistency)
        XCTAssertEqual(change.afterVerdict, .agreement)
        XCTAssertEqual(change.matchBasis, "exact_image_offset")
    }
}
