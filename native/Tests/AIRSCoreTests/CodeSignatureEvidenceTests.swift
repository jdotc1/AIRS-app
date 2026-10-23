import CryptoKit
import Foundation
import XCTest
@testable import AIRSCore

final class CodeSignatureEvidenceTests: XCTestCase {
    private func word(_ value: UInt32, little: Bool = true) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : 3 - $0) * 8)) })
    }
    private func blob(_ magic: UInt32, _ payload: Data) -> Data {
        word(magic, little: false) + word(UInt32(payload.count + 8), little: false) + payload
    }
    private func signature(_ records: [(UInt32, Data)]) -> Data {
        var table = Data(), body = Data(), offset = 12 + records.count * 8
        for (type, bytes) in records {
            table += word(type, little: false) + word(UInt32(offset), little: false)
            body += bytes; offset += bytes.count
        }
        return word(0xfade0cc0, little: false) + word(UInt32(offset), little: false)
            + word(UInt32(records.count), little: false) + table + body
    }
    private func thin(_ signature: Data?, cpu: UInt32 = 0x0100000c, subtype: UInt32 = 0,
                      duplicate: Bool = false) -> Data {
        let commands = signature == nil ? 0 : (duplicate ? 2 : 1)
        var bytes = Data([0xcf, 0xfa, 0xed, 0xfe])
        for value in [cpu, subtype, 2, UInt32(commands), UInt32(commands * 16), 0, 0] { bytes += word(value) }
        if let signature {
            for _ in 0..<commands {
                for value: UInt32 in [0x1d, 16, 128, UInt32(signature.count)] { bytes += word(value) }
            }
            bytes += Data(repeating: 0, count: 128 - bytes.count); bytes += signature
        }
        return bytes
    }
    private func fat(_ values: [(UInt32, UInt32, Data)]) -> Data {
        var bytes = word(0xcafebabe, little: false) + word(UInt32(values.count), little: false)
        for (index, value) in values.enumerated() {
            for field in [value.0, value.1, UInt32((index + 1) * 4096), UInt32(value.2.count), 12] {
                bytes += word(field, little: false)
            }
        }
        for (index, value) in values.enumerated() {
            bytes += Data(repeating: 0, count: (index + 1) * 4096 - bytes.count); bytes += value.2
        }
        return bytes
    }
    private func withImage<T>(_ bytes: Data, _ body: (BundleImageProvenance, URL) throws -> T) throws -> T {
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("AIRS-signature-tests-\(UUID())/Owned.app")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let image = root.appendingPathComponent("Contents/MacOS/Main")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: image)
        let plist = ["CFBundleExecutable": "Main", "CFBundleIdentifier": "example.signature"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let unit = try XCTUnwrap(BundleDiscovery().discover(root).entries.first { $0.relativePath == "Contents/MacOS/Main" }?.provenance)
        return try body(unit, image)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testRawXMLAndDERRemainExactBytesWithNoSemanticDecode() throws {
        // Deliberately not valid XML or DER: this feature records representation,
        // not interpreted entitlement values or signature validity.
        let xml = blob(0xfade7171, Data([0xff, 0x00, 0x61]))
        let der = blob(0xfade7172, Data([0x00, 0xff, 0x00, 0x7f]))
        let raw = signature([(5, xml), (7, der)]), source = thin(raw, subtype: 0x80000002)
        try withImage(source) { unit, _ in
            let result = try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.containerSHA256, digest(source))
            XCTAssertEqual(result.bytesHashed, UInt64(source.count))
            let slice = try XCTUnwrap(result.slices.first)
            XCTAssertEqual(slice.cpuSubtype, 0x80000002)
            XCTAssertEqual(slice.state, .collected)
            XCTAssertEqual(slice.signatureOffset, 128)
            XCTAssertEqual(slice.signatureBytes, raw)
            XCTAssertEqual(slice.sliceSHA256, digest(source))
            XCTAssertEqual(slice.slots.map(\.bytes), [xml, der])
            XCTAssertEqual(slice.slots.map(\.type), [5, 7])
            XCTAssertEqual(slice.slots.map(\.containerOffset), [156, UInt64(156 + xml.count)])
            XCTAssertEqual(slice.slots.map(\.sha256), [digest(xml), digest(der)])
            try result.validate()
        }
    }

    func testExactUniversalSlicesAndIntelRemainUnexamined() throws {
        let raw = signature([(5, blob(0xfade7171, Data([1])))])
        let source = fat([(0x0100000c, 0, thin(nil)),
                          (0x0100000c, 0x80000002, thin(raw, subtype: 0x80000002)),
                          (0x01000007, 3, thin(raw, cpu: 0x01000007, subtype: 3))])
        try withImage(source) { unit, _ in
            let result = try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.slices.map(\.sliceOffset), [4096, 8192, 12288])
            XCTAssertEqual(result.slices.map(\.state), [.signatureAbsent, .collected, .unexamined])
            XCTAssertEqual(result.slices[1].signatureOffset, 8320)
            XCTAssertNil(result.slices[2].signatureBytes)
            XCTAssertTrue(result.slices[2].slots.isEmpty)
        }
    }

    func testMissingSignatureAndMissingEntitlementSlotsAreDifferent() throws {
        for (source, state) in [(thin(nil), CodeSignatureEvidenceState.signatureAbsent),
                                (thin(nil, subtype: 1), .signatureAbsent),
                                (thin(signature([(0, blob(0xfade0c02, Data([1, 2])))])), .entitlementsAbsent)] {
            try withImage(source) { unit, _ in
                XCTAssertEqual(try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID()).slices[0].state, state)
            }
        }
    }

    func testRejectsOverlapAndAliasesAcrossNonEntitlementSlots() throws {
        let first = blob(0xfade0c02, Data(repeating: 0, count: 24))
        let second = blob(0xfade7171, Data([1]))
        let valid = signature([(0, first), (5, second)])
        var overlap = valid; overlap.replaceSubrange(24..<28, with: word(36, little: false))
        overlap.replaceSubrange(36..<44, with: blob(0xfade7171, Data()).prefix(8))
        var alias = valid; alias.replaceSubrange(24..<28, with: word(28, little: false))
        var duplicate = valid; duplicate.replaceSubrange(20..<24, with: word(0, little: false))
        var tableOverlap = valid; tableOverlap.replaceSubrange(16..<20, with: word(12, little: false))
        var nonEntitlementAlias = signature([(0, first), (2, first)])
        nonEntitlementAlias.replaceSubrange(24..<28, with: word(28, little: false))
        for malformed in [overlap, alias, duplicate, tableOverlap, nonEntitlementAlias] {
            XCTAssertThrowsError(try BoundedCodeSignatureParser.parse(malformed, containerOffset: 128, sliceOffset: 0, maximumSlotCount: 4096))
            try withImage(thin(malformed)) { unit, _ in
                let result = try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
                XCTAssertEqual(result.slices[0].state, .malformed)
                XCTAssertTrue(result.slices[0].slots.isEmpty)
                try result.validate()
            }
        }
    }

    func testMalformedMagicCountLengthsAndSignatureCommandsStayExplicit() throws {
        let good = signature([(5, blob(0xfade7171, Data([1])))])
        var badMagic = good; badMagic.replaceSubrange(0..<4, with: word(0, little: false))
        var badCount = good; badCount.replaceSubrange(8..<12, with: word(UInt32.max, little: false))
        var badLength = good; badLength.replaceSubrange(4..<8, with: word(UInt32.max, little: false))
        var wrongSlotMagic = good; wrongSlotMagic.replaceSubrange(20..<24, with: word(0xfade7172, little: false))
        var wrongXMLType = good; wrongXMLType.replaceSubrange(12..<16, with: word(9, little: false))
        let wrongDERType = signature([(9, blob(0xfade7172, Data([1])))])
        var outside = thin(good); outside.replaceSubrange(40..<44, with: word(UInt32.max))
        var headerOverlap = thin(good); headerOverlap.replaceSubrange(40..<44, with: word(16))
        for source in [thin(Data(good.prefix(11))), thin(badMagic), thin(badCount), thin(badLength),
                       thin(wrongSlotMagic), thin(wrongXMLType), thin(wrongDERType),
                       thin(good, duplicate: true), outside, headerOverlap] {
            try withImage(source) { unit, _ in
                let result = try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
                XCTAssertEqual(result.slices[0].state, .malformed)
                try result.validate()
            }
        }
    }

    func testSignatureAndAggregateBudgetsDoNotBecomeAbsence() throws {
        let raw = signature([(5, blob(0xfade7171, Data([1])))])
        let limits = CodeSignatureEvidenceLimits(maximumSignatureBytes: raw.count - 1)
        try withImage(thin(raw)) { unit, _ in
            let result = try CodeSignatureEvidenceReader(limits: limits).capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.slices[0].state, .budgetExceeded)
            XCTAssertEqual(result.signatureBytesRead, 0)
            try result.validate()
        }
        let source = fat([(0x0100000c, 0, thin(raw)), (0x0100000c, 2, thin(raw, subtype: 2))])
        let aggregate = CodeSignatureEvidenceLimits(maximumTotalSignatureBytes: raw.count)
        try withImage(source) { unit, _ in
            let result = try CodeSignatureEvidenceReader(limits: aggregate).capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.slices.map(\.state), [.collected, .budgetExceeded])
            XCTAssertEqual(result.signatureBytesRead, raw.count)
            try result.validate()
        }
        let manySlots = signature([(0, blob(0xfade0c02, Data([1]))), (5, blob(0xfade7171, Data([2])))])
        try withImage(thin(manySlots)) { unit, _ in
            let result = try CodeSignatureEvidenceReader(limits: .init(maximumSlotCount: 1)).capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.slices[0].state, .budgetExceeded)
            XCTAssertEqual(result.slices[0].problem, .slotBudget)
            XCTAssertEqual(result.slices[0].signatureBytes, manySlots)
            try result.validate()
        }
    }

    func testStreamingHashIncludesBytesAcrossChunkBoundaries() throws {
        let raw = signature([(5, blob(0xfade7171, Data([1])))])
        let source = thin(raw) + Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
        try withImage(source) { unit, _ in
            let result = try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
            XCTAssertEqual(result.containerSHA256, digest(source))
            XCTAssertEqual(result.slices[0].sliceSHA256, digest(source))
            XCTAssertEqual(result.signatureBytesRead, raw.count)
            XCTAssertEqual(result.bytesHashed, UInt64(source.count))
        }
    }

    func testCancelledCaptureCannotPublishEvidence() async throws {
        let pending = try withImage(thin(nil)) { unit, _ in
            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID())
            }
            task.cancel()
            return task
        }
        do { _ = try await pending.value; XCTFail("Cancelled capture published evidence.") }
        catch is CancellationError { }
    }

    func testStaleProvenanceBadFatAndContainerBudgetCannotPublishEvidence() throws {
        let source = thin(nil)
        try withImage(source) { unit, image in
            XCTAssertThrowsError(try CodeSignatureEvidenceReader(limits: .init(maximumContainerBytes: 1)).capture(unit: unit, componentID: UUID()))
            XCTAssertThrowsError(try CodeSignatureEvidenceReader(limits: .init(maximumHeaderBytes: 8)).capture(unit: unit, componentID: UUID()))
            try thin(signature([])).write(to: image)
            XCTAssertThrowsError(try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID()))
        }
        var mismatch = fat([(0x0100000c, 0, source)])
        mismatch.replaceSubrange(12..<16, with: word(2, little: false))
        try withImage(mismatch) { unit, _ in
            XCTAssertThrowsError(try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID()))
        }
        var overlap = fat([(0x0100000c, 0, source), (0x0100000c, 2, thin(nil, subtype: 2))])
        overlap.replaceSubrange(36..<40, with: word(4096, little: false))
        try withImage(overlap) { unit, _ in
            XCTAssertThrowsError(try CodeSignatureEvidenceReader().capture(unit: unit, componentID: UUID()))
        }
    }
}
