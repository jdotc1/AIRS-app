import CryptoKit
import Foundation
import XCTest
import AIRSCore
@testable import AIRSEntitlements

final class CodeSignatureEvidenceDocumentTests: XCTestCase {
    private func captured() throws -> CodeSignatureEvidenceDocument {
        func word(_ value: UInt32, little: Bool = true) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : 3 - $0) * 8)) })
        }
        var raw = Data()
        for value: UInt32 in [0xfade0cc0, 31, 1, 5, 20, 0xfade7171, 11] { raw += word(value, little: false) }
        raw += Data([0xff, 0, 0x61])
        var source = Data([0xcf, 0xfa, 0xed, 0xfe])
        for value: UInt32 in [0x0100000c, 0x80000002, 2, 1, 16, 0, 0, 0x1d, 16, 128, 31] { source += word(value) }
        source += Data(repeating: 0, count: 128 - source.count); source += raw
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("AIRS-signature-document-\(UUID())/Owned.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let image = root.appendingPathComponent("Contents/MacOS/Main")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: image)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Main"], format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let unit = try XCTUnwrap(BundleDiscovery().discover(root).entries.first { $0.relativePath == "Contents/MacOS/Main" }?.provenance)
        return try CodeSignatureEvidenceDocument.capture(unit: unit, componentID: UUID(), producerVersion: "test")
    }
    private func edited(_ bytes: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try change(&json)
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
    private func editSlice(_ bytes: Data, _ change: (inout [String: Any]) throws -> Void) throws -> Data {
        try edited(bytes) { json in
            var evidence = try XCTUnwrap(json["evidence"] as? [String: Any])
            var slices = try XCTUnwrap(evidence["slices"] as? [[String: Any]])
            try change(&slices[0]); evidence["slices"] = slices; json["evidence"] = evidence
        }
    }

    func testDocumentAndArchiveRetainRawBytesWithoutLiveSource() throws {
        // captured() removes the source before return: successful import must
        // remain historical evidence and cannot rebuild a live file capability.
        let original = try captured(), bytes = try original.data()
        let decoded = try CodeSignatureEvidenceDocument.decode(bytes)
        XCTAssertEqual(decoded.evidence, original.evidence)
        XCTAssertEqual(decoded.evidence.slices[0].slots[0].bytes, Data([0xfa, 0xde, 0x71, 0x71, 0, 0, 0, 11, 0xff, 0, 0x61]))
        let archive = try InspectionArchive.decode(original.archive())
        let item = try XCTUnwrap(archive.attachments.first)
        XCTAssertEqual(item.bytes, bytes)
        XCTAssertEqual(try archive.validation(for: item.id), .supported)
        XCTAssertEqual(archive.components.first?.id, original.evidence.componentID)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("/Owned.app"))
    }

    func testImportReparsesRetainedSuperBlobAndRejectsForgedSlots() throws {
        let bytes = try captured().data()
        for field in ["containerOffset", "sliceRelativeOffset", "byteCount", "magic", "type", "sha256", "bytes"] {
            let malformed = try editSlice(bytes) { slice in
                var slots = try XCTUnwrap(slice["slots"] as? [[String: Any]])
                if field == "sha256" { slots[0][field] = String(repeating: "0", count: 64) }
                else if field == "bytes" { slots[0][field] = Data([0]).base64EncodedString() }
                else { slots[0][field] = 0 }
                slice["slots"] = slots
            }
            XCTAssertThrowsError(try CodeSignatureEvidenceDocument.decode(malformed), field)
        }
        let badSignatureHash = try editSlice(bytes) { $0["signatureSHA256"] = String(repeating: "0", count: 64) }
        let missingSuccessBytes = try editSlice(bytes) { $0.removeValue(forKey: "signatureBytes") }
        let missingSuccessSlots = try editSlice(bytes) { $0["slots"] = [] }
        let falseAbsence = try editSlice(bytes) { $0["state"] = "signatureAbsent" }
        let falseUnsupported = try editSlice(bytes) { $0["state"] = "unexamined" }
        let falseMalformed = try editSlice(bytes) { $0["state"] = "malformed"; $0["problem"] = "invalidSuperBlob"; $0["slots"] = [] }
        for malformed in [badSignatureHash, missingSuccessBytes, missingSuccessSlots, falseAbsence, falseUnsupported, falseMalformed] {
            XCTAssertThrowsError(try CodeSignatureEvidenceDocument.decode(malformed))
        }
    }

    func testRejectsUnknownFieldsDuplicateKeysNumericCoercionAndImpossibleRanges() throws {
        let bytes = try captured().data()
        let added = try editSlice(bytes) { $0["signatureTrusted"] = true }
        let outside = try editSlice(bytes) { $0["sliceOffset"] = UInt64.max }
        let cpuBoolean = try editSlice(bytes) { $0["cpuType"] = true }
        let beyondUInt32 = try editSlice(bytes) { $0["cpuSubtype"] = UInt64(UInt32.max) + 1 }
        for malformed in [added, outside, cpuBoolean, beyondUInt32] {
            XCTAssertThrowsError(try CodeSignatureEvidenceDocument.decode(malformed))
        }
        let text = String(decoding: bytes, as: UTF8.self)
        for malformed in [text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
                          text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                          text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")] {
            XCTAssertThrowsError(try CodeSignatureEvidenceDocument.decode(Data(malformed.utf8)))
        }
    }
}
