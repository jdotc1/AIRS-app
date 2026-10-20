import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

/// Handoff tests written before the implementation; NOT RUN in the Linux workspace.
/// Run on macOS with the package's Swift toolchain before accepting this change.
final class InspectionDocumentTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000.125)

    private func snapshot(_ values: EntitlementDictionary = .init(),
                          presence: EntitlementPresence = .dictionaryPresent,
                          origin: SnapshotOrigin = .extracted,
                          saved: Bool = false, identity: AppIdentity? = nil) -> EntitlementSnapshot {
        .init(sourceName: "Example.app", signingIdentifier: "example.application",
              architecture: .arm64, presence: presence, origin: origin,
              entitlements: values, identity: identity, isSavedBaseline: saved)
    }

    private func document(_ snapshot: EntitlementSnapshot? = nil) throws -> InspectionDocument {
        try .init(snapshot: snapshot ?? self.snapshot(), capturedAt: capturedAt, producerVersion: "1.2.3+4")
    }

    // Tiny owned JSON fixtures. No target program is loaded or executed by these tests.
    private func rawSnapshot(value: String? = nil, entries: String? = nil) -> String {
        let content = entries ?? value.map { #"[{"key":"example","value":\#($0)}]"# } ?? "[]"
        return """
        {"sourceName":"Example.app","signingIdentifier":"example.application",
         "architecture":"arm64","presence":"dictionaryPresent","origin":"extracted",
         "entitlements":\(content)}
        """
    }

    private func envelope(snapshot: String? = nil, identity: String = "null",
                          version: String = "1", date: String = "1800000000.125",
                          extra: String = "") -> Data {
        Data("""
        {"kind":"airs.inspection","schemaVersion":\(version),
         "scope":"mainExecutableRequestedArchitecture",
         "signatureValidation":"notPerformed","gatekeeperAssessment":"notPerformed",
         "capturedAtUnixSeconds":\(date),"producerVersion":"1.2.3+4",
         "captureProvenance":"nativeExtraction","originalBinaryRetained":false,
         "identity":\(identity),"snapshot":\(snapshot ?? rawSnapshot())\(extra)}
        """.utf8)
    }

    private func assertLimit(_ operation: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            guard case InspectionDocumentError.limit = $0 else {
                return XCTFail("Expected the document import limit, received \($0).", file: file, line: line)
            }
        }
    }

    func testStandaloneRoundTripPreservesCapturedMetadataAndMarksImportedSnapshot() throws {
        let identity = AppIdentity(infoPlist: ["CFBundleIdentifier": "example.application",
                                             "CFBundleShortVersionString": "1/2",
                                             "CFBundleVersion": "e\u{301}"])
        let original = try document(snapshot(identity: identity))
        let bytes = try InspectionDocumentCodec.encode(original)
        let restored = try InspectionDocumentCodec.decode(bytes)
        XCTAssertEqual(restored.capturedAt, capturedAt)
        XCTAssertEqual(restored.producerVersion, "1.2.3+4")
        XCTAssertEqual(restored.identity?.version, "1/2")
        XCTAssertEqual(restored.snapshot.identity?.version, "1/2")
        XCTAssertEqual(Array(try XCTUnwrap(restored.identity?.build).utf8), Array("e\u{301}".utf8))
        XCTAssertEqual(restored.captureProvenance, .nativeExtraction)
        XCTAssertFalse(original.snapshot.isSavedBaseline)
        XCTAssertTrue(restored.snapshot.isSavedBaseline)
        XCTAssertFalse(restored.originalBinaryRetained)
        XCTAssertEqual(try InspectionDocumentCodec.encode(restored), bytes)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "schemaVersion", "scope", "signatureValidation",
            "gatekeeperAssessment", "capturedAtUnixSeconds", "producerVersion", "captureProvenance",
            "originalBinaryRetained", "identity", "snapshot"])
        let captured = try XCTUnwrap(object["snapshot"] as? [String: Any])
        XCTAssertEqual(Set(captured.keys), ["sourceName", "signingIdentifier", "architecture",
                                          "presence", "origin", "entitlements"])
        XCTAssertNil(object["previous"])
        XCTAssertNil(object["current"])
        XCTAssertNil(object["sourcePath"])
        XCTAssertNil(object["binaryHash"])
    }

    func testExactTypedValuesAndDistinctUnicodeKeysSurviveBothCodecs() throws {
        let entries = try EntitlementDictionary(entries: [
            .init(key: "\u{e9}", value: .string("\u{e9}")),
            .init(key: "e\u{301}", value: .string("e\u{301}")),
            .init(key: "types", value: .array([
                .boolean(false), .integer(Int64.min), .unsignedInteger(UInt64.max),
                .real(-0.0), .real(Double.leastNonzeroMagnitude), .real(Double.greatestFiniteMagnitude),
                .date(Date(timeIntervalSinceReferenceDate: 0.125)),
                .data(Data([0, 1, 127, 255])), .dictionary(.init(["empty": .array([])]))
            ]))
        ])
        let source = snapshot(entries)
        let standalone = try EntitlementSnapshotJSONCodec.decode(EntitlementSnapshotJSONCodec.encode(source))
        XCTAssertEqual(standalone.entitlements, entries)
        XCTAssertTrue(standalone.isSavedBaseline)
        let restored = try InspectionDocumentCodec.decode(InspectionDocumentCodec.encode(document(source)))
        XCTAssertEqual(restored.snapshot.entitlements, entries)
        XCTAssertEqual(restored.snapshot.entitlements.entries.count, 3)
    }

    func testAbsentEntitlementsRemainDistinctFromPresentEmptyDictionary() throws {
        let absent = try InspectionDocumentCodec.decode(InspectionDocumentCodec.encode(document(
            snapshot(presence: .notPresent))))
        let empty = try InspectionDocumentCodec.decode(InspectionDocumentCodec.encode(document(snapshot())))
        XCTAssertEqual(absent.snapshot.presence, .notPresent)
        XCTAssertEqual(empty.snapshot.presence, .dictionaryPresent)
        XCTAssertTrue(absent.snapshot.entitlements.entries.isEmpty)
        XCTAssertTrue(empty.snapshot.entitlements.entries.isEmpty)
        XCTAssertThrowsError(try document(snapshot(.init(["a": .boolean(true)]), presence: .notPresent)))
    }

    func testCreationProvenanceDistinguishesNativeSavedAndSyntheticInputs() throws {
        XCTAssertEqual(try document(snapshot()).captureProvenance, .nativeExtraction)
        XCTAssertEqual(try document(snapshot(saved: true)).captureProvenance, .savedSnapshot)
        XCTAssertEqual(try document(snapshot(origin: .syntheticExample)).captureProvenance, .syntheticExample)
        XCTAssertEqual(try document(snapshot(origin: .syntheticExample, saved: true)).captureProvenance, .syntheticExample)
        let mismatched = String(decoding: envelope(), as: UTF8.self)
            .replacingOccurrences(of: #""captureProvenance":"nativeExtraction""#,
                                  with: #""captureProvenance":"syntheticExample""#)
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(Data(mismatched.utf8)))
    }

    func testUnknownVersionsMalformedDatesAndMetadataAreRejected() throws {
        for version in ["0", "2", "1.0", "true", #""1""#, "null"] {
            XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(version: version)), version)
        }
        for date in [#""yesterday""#, "null", "false", "1e999", "978307199", "253402300800"] {
            XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(date: date)), date)
        }
        for producer in ["", "v1.2.3", "1/2", "1\n2", String(repeating: "1", count: 65)] {
            XCTAssertThrowsError(try InspectionDocument(snapshot: snapshot(), capturedAt: capturedAt,
                                                         producerVersion: producer))
        }
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
                     Date(timeIntervalSince1970: 978_307_199)] {
            XCTAssertThrowsError(try InspectionDocument(snapshot: snapshot(), capturedAt: date, producerVersion: "1"))
        }
        _ = try InspectionIdentity(version: String(repeating: "\u{e9}", count: 128))
        XCTAssertThrowsError(try InspectionIdentity(version: String(repeating: "\u{e9}", count: 129)))
        XCTAssertThrowsError(try InspectionIdentity(build: "line\nbreak"))
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(identity:
            #"{"bundleIdentifier":null,"version":null,"build":null,"sourcePath":"/private/example"}"#)))
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(identity:
            #"{"bundleIdentifier":null,"version":true,"build":null}"#)))
    }

    func testDuplicateEnvelopeMetadataSnapshotAndEntitlementKeysAreRejected() throws {
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(extra: #","producerVersion":"9""#)))
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(extra: #","schem\u0061Version":1"#)))
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(identity:
            #"{"bundleIdentifier":null,"version":"1","version":"2","build":null}"#)))
        let duplicateSnapshot = String(rawSnapshot().dropLast()) + #","sourceName":"Other.app"}"#
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(snapshot: String(duplicateSnapshot))))
        let duplicateEntries = #"[{"key":"a","value":{"type":"boolean","value":true}},{"key":"a","value":{"type":"boolean","value":false}}]"#
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(snapshot: rawSnapshot(entries: duplicateEntries))))
    }

    func testMalformedTypedValuesAndUnexpectedClaimsAreRejected() throws {
        for value in [
            #"{"type":"integer","value":"-01"}"#,
            #"{"type":"integer","value":"18446744073709551616"}"#,
            #"{"type":"integer","value":1}"#,
            #"{"type":"boolean","value":"true"}"#,
            #"{"type":"real","value":1e999}"#,
            #"{"type":"date-reference-seconds","value":"1"}"#,
            #"{"type":"data-base64","value":"AA"}"#,
            #"{"type":"string","value":"x","sourcePath":"elsewhere"}"#
        ] {
            XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(snapshot: rawSnapshot(value: value))), value)
        }
        let valid = String(decoding: envelope(), as: UTF8.self)
        for invalid in [
            valid.replacingOccurrences(of: #""originalBinaryRetained":false"#, with: #""originalBinaryRetained":true"#),
            valid.replacingOccurrences(of: #""signatureValidation":"notPerformed""#, with: #""signatureValidation":"valid""#),
            valid.replacingOccurrences(of: #""scope":"mainExecutableRequestedArchitecture""#, with: #""scope":"wholeBundle""#),
            valid.replacingOccurrences(of: #""sourceName":"Example.app""#, with: #""sourceName":"/tmp/Example.app""#),
            valid + "{}",
            "{",
            ""
        ] {
            XCTAssertThrowsError(try InspectionDocumentCodec.decode(Data(invalid.utf8)))
        }
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(envelope(extra: #","sourcePath":"/tmp/Example.app""#)))
    }

    func testWholeDocumentByteStringDepthAndNodeBudgetsAreEnforced() throws {
        assertLimit { _ = try InspectionDocumentCodec.decode(Data(repeating: 32, count: InspectionDocumentCodec.maximumBytes + 1)) }
        let string = String(repeating: "x", count: 1_024 * 1_024 + 1)
        assertLimit { _ = try InspectionDocumentCodec.decode(envelope(snapshot:
            rawSnapshot(value: #"{"type":"string","value":"\#(string)"}"#))) }
        let deep = String(repeating: #"{"type":"array","value":["#, count: 50)
            + #"{"type":"boolean","value":true}"# + String(repeating: "]}", count: 50)
        assertLimit { _ = try InspectionDocumentCodec.decode(envelope(snapshot: rawSnapshot(value: deep))) }
        let many = "[" + Array(repeating: #"{"type":"boolean","value":true}"#, count: 34_000).joined(separator: ",") + "]"
        assertLimit { _ = try InspectionDocumentCodec.decode(envelope(snapshot:
            rawSnapshot(value: #"{"type":"array","value":\#(many)}"#))) }
    }

    func testPathLookingEntitlementValuesAndCapturedLabelsArePreservedAsContent() throws {
        let source = snapshot(.init(["selected": .string("/Users/example/Document")]),
            identity: AppIdentity(infoPlist: ["CFBundleShortVersionString": #"release\branch/1"#]))
        let restored = try InspectionDocumentCodec.decode(InspectionDocumentCodec.encode(document(source)))
        XCTAssertEqual(restored.snapshot.entitlements, source.entitlements)
        XCTAssertEqual(restored.identity?.version, #"release\branch/1"#)
    }

    func testLegacyComparisonStillRoundTripsWithoutInspectionFields() throws {
        let previous = snapshot(.init(["a": .integer(1)]), presence: .dictionaryPresent)
        let current = snapshot(.init(["a": .integer(2), "b": .boolean(false)]))
        let oldBytes = try ComparisonReport(previous: previous, current: current).jsonData()
        let saved = try SavedReport.parse(oldBytes)
        XCTAssertEqual(saved.previous.entitlements, previous.entitlements)
        XCTAssertEqual(saved.current.entitlements, current.entitlements)
        let reexported = try ComparisonReport(previous: saved.previous, current: saved.current).jsonData()
        let reread = try SavedReport.parse(reexported)
        XCTAssertEqual(reread.previous.entitlements, previous.entitlements)
        XCTAssertEqual(reread.current.entitlements, current.entitlements)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reexported) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "tool", "scope", "signatureValidation",
            "gatekeeperAssessment", "previous", "current", "changes", "unchangedCount", "notices"])
        XCTAssertThrowsError(try SavedReport.parse(InspectionDocumentCodec.encode(document())))
        XCTAssertThrowsError(try InspectionDocumentCodec.decode(oldBytes))
    }

    func testReadAcceptsOnlyBoundedLocalRegularDocumentFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example.airsinspect")
        try InspectionDocumentCodec.encode(document()).write(to: file)
        XCTAssertEqual(try InspectionDocumentCodec.read(at: file).snapshot.signingIdentifier, "example.application")
        XCTAssertThrowsError(try InspectionDocumentCodec.read(at: directory))
        XCTAssertThrowsError(try InspectionDocumentCodec.read(at: XCTUnwrap(URL(string: "https://invalid.example/document"))))
        try Data(repeating: 32, count: InspectionDocumentCodec.maximumBytes + 1).write(to: file)
        assertLimit { _ = try InspectionDocumentCodec.read(at: file) }
    }
}
