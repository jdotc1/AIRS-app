import XCTest
import CryptoKit
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class InspectionArchiveTests: XCTestCase {
    private func attachment(_ bytes: Data, kind: String = "airs.inspection", version: Int = 1,
                            id: UUID = UUID()) -> EvidenceAttachment {
        .init(id: id, kind: kind, schemaVersion: version, mediaType: "application/json",
              sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
              byteCount: bytes.count, bytes: bytes)
    }
    private func inspection() throws -> Data {
        var bytes = Data(" \n".utf8)
        bytes.append(try InspectionDocumentCodec.encode(.init(
            snapshot: ExampleSnapshots.pair(architecture: .arm64).current,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")))
        return bytes
    }
    func testOriginalInspectionAndComparisonBytesSurvive() throws {
        let bytes = try inspection(), pair = ExampleSnapshots.pair(architecture: .arm64)
        let comparison = try ComparisonReport(previous: pair.previous, current: pair.current).jsonData()
        let items = [attachment(bytes), attachment(comparison, kind: "EntitlementDiff")]
        let decoded = try InspectionArchive.decode(InspectionArchive(attachments: items).encode())
        XCTAssertEqual(decoded.attachments.map(\.bytes), [bytes, comparison])
        XCTAssertEqual(try decoded.validation(for: items[0].id), .supported)
        XCTAssertEqual(try decoded.validation(for: items[1].id), .supported)
    }
    func testAttachmentDigestMismatchRejected() throws {
        let valid = attachment(try inspection())
        let wrong = EvidenceAttachment(id: valid.id, kind: valid.kind, schemaVersion: 1,
            mediaType: valid.mediaType, sha256: String(repeating: "0", count: 64),
            byteCount: valid.byteCount, bytes: valid.bytes)
        XCTAssertThrowsError(try InspectionArchive(attachments: [wrong]).encode())
    }
    func testSameFilenameDoesNotJoinEvidence() throws {
        let first = attachment(Data("first".utf8), kind: "example.filename"), second = attachment(Data("second".utf8), kind: "example.filename")
        let archive = try InspectionArchive.decode(InspectionArchive(attachments: [first, second]).encode())
        XCTAssertNotEqual(archive.attachments[0].id, archive.attachments[1].id)
        XCTAssertEqual(archive.attachments.map(\.bytes), [first.bytes, second.bytes])
        XCTAssertThrowsError(try InspectionArchive(attachments: [first, first]).encode())
    }
    func testUnsupportedAttachmentVisibleButNotTrusted() throws {
        let unknown = attachment(Data("opaque".utf8), kind: "future.assessment", version: 7)
        let archive = try InspectionArchive.decode(InspectionArchive(attachments: [unknown]).encode())
        XCTAssertEqual(archive.attachments[0].bytes, unknown.bytes)
        XCTAssertEqual(try archive.validation(for: unknown.id), .uninterpreted)
        let futureKnown = attachment(try inspection(), version: 2)
        XCTAssertEqual(try InspectionArchive.decode(InspectionArchive(attachments: [futureKnown]).encode()).validation(for: futureKnown.id), .uninterpreted)
    }
    func testImportedValidationCannotEstablishTrustAndDuplicateEnvelopeRejected() throws {
        let bytes = try InspectionArchive(attachments: []).encode()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json["validation"] = "supported"
        XCTAssertThrowsError(try InspectionArchive.decode(JSONSerialization.data(withJSONObject: json)))
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        let duplicate = text.replacingOccurrences(of: "\"kind\"", with: "\"kind\":\"airs.review\",\"kind\"", options: [], range: text.range(of: "\"kind\""))
        XCTAssertThrowsError(try InspectionArchive.decode(Data(duplicate.utf8)))
    }
    func testArchiveVersionLengthAndKnownPayloadFailure() throws {
        XCTAssertThrowsError(try InspectionArchive.decode(Data(#"{"kind":"airs.review","schemaVersion":2,"attachments":[],"components":[]}"#.utf8))) {
            XCTAssertEqual($0 as? InspectionArchiveError, .unsupportedVersion)
        }
        let valid = attachment(Data("{}".utf8))
        XCTAssertThrowsError(try InspectionArchive(attachments: [valid]).encode())
        let wrongLength = EvidenceAttachment(id: valid.id, kind: "opaque", schemaVersion: 1,
            mediaType: valid.mediaType, sha256: valid.sha256, byteCount: 20, bytes: valid.bytes)
        XCTAssertThrowsError(try InspectionArchive(attachments: [wrongLength]).encode())
    }
    func testArchiveLimitsAndComponentReferences() throws {
        let one = attachment(Data("opaque".utf8), kind: "future")
        XCTAssertThrowsError(try InspectionArchive(attachments: (0..<257).map { _ in attachment(one.bytes, kind: "future") }).encode())
        XCTAssertThrowsError(try InspectionArchive.decode(Data(repeating: 32, count: InspectionArchive.maximumBytes + 1)))
        XCTAssertThrowsError(try InspectionArchive(attachments: [one], components: [.init(id: UUID(), evidenceIDs: [UUID()])]).encode())
        XCTAssertThrowsError(try InspectionArchive(attachments: [], components: (0..<129).map { _ in .init(id: UUID(), evidenceIDs: []) }).encode())
    }
    func testAuditCompatibilityAndMalformedChunks() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        let item = attachment(original, kind: "airs.audit")
        let archive = try InspectionArchive.decode(InspectionArchive(attachments: [item]).encode())
        XCTAssertEqual(archive.attachments[0].bytes, original)
        XCTAssertEqual(try archive.validation(for: item.id), .supported)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: archive.encode()) as? [String: Any])
        var attachments = try XCTUnwrap(json["attachments"] as? [[String: Any]])
        attachments[0]["chunks"] = ["not!base64"]
        json["attachments"] = attachments
        XCTAssertThrowsError(try InspectionArchive.decode(JSONSerialization.data(withJSONObject: json)))
    }
    func testReferenceLimitRejectsBeforeUUIDDecoding() throws {
        let json: [String: Any] = ["kind": "airs.review", "schemaVersion": 1, "attachments": [],
            "components": [["id": UUID().uuidString, "evidenceIDs": Array(repeating: "not-a-UUID", count: 257)]]]
        XCTAssertThrowsError(try InspectionArchive.decode(JSONSerialization.data(withJSONObject: json))) {
            XCTAssertEqual($0 as? InspectionArchiveError, .limit, "Reject the count before attempting to decode a reference")
        }
    }
    func testOriginalLegacyComparisonAndComponentBindingRoundTrip() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: project.appendingPathComponent("fixtures/entitlements/inspector-report.json"))
        let item = attachment(bytes, kind: "EntitlementDiff")
        let reference = ArchiveComponentReference(id: UUID(), evidenceIDs: [item.id])
        let archive = try InspectionArchive.decode(InspectionArchive(attachments: [item], components: [reference]).encode())
        XCTAssertEqual(archive.attachments[0].bytes, bytes)
        XCTAssertEqual(archive.components[0].evidenceIDs, [item.id])
        XCTAssertEqual(try archive.validation(for: item.id), .supported)
    }
    func testChunkedOpaqueBytesRoundTripBeyondStringLimit() throws {
        let item = attachment(Data(repeating: 65, count: 1_500_000), kind: "future")
        XCTAssertEqual(try InspectionArchive.decode(InspectionArchive(attachments: [item]).encode()).attachments[0].bytes, item.bytes)
    }
}
