import CryptoKit
import Foundation
import XCTest
@testable import AIRSCore

final class ReportLibraryTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/report-library-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func data() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures")))
    }

    func testPreExtractionVersionOneReceiptRemainsReadable() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try data(); let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try raw.write(to: directory.appendingPathComponent("report.json"))
        // Construct the original schema independently of the extracted store's encoder.
        let receipt: [String: Any] = ["version": 1, "id": id.uuidString,
            "savedAt": 1000.0,
            "reportSHA256": SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
            "provenance": ["sourceLabel": "Existing audit library", "inspectedInput": "file:///owned/input.macho"]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("receipt.json"))
        let store = ReportLibrary(root: root)
        let retained = try await store.load(id)
        XCTAssertEqual(retained.data, raw)
        XCTAssertEqual(retained.provenance.inspectedInput?.path, "/owned/input.macho")
        let entries = try await store.entries()
        XCTAssertEqual(entries.first?.id, id)
        XCTAssertEqual(entries.first?.savedAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertNil(entries.first?.issue)
    }

    func testRawBytesUnknownFieldsAndProvenanceSurviveNewStore() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["future_extension"] = ["retained": true]
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) + Data("\n \n".utf8)
        let provenance = LibraryProvenance(sourceLabel: "Owned report", inspectedInput: root.appendingPathComponent("original.macho"), symbolInput: root.appendingPathComponent("original.dSYM"))
        let store = ReportLibrary(root: root)
        let id = try await store.keep(raw, provenance: provenance)
        let reopened = try await ReportLibrary(root: root).load(id)
        XCTAssertEqual(reopened.data, raw)
        XCTAssertEqual(reopened.provenance.inspectedInput, provenance.inspectedInput)
        XCTAssertEqual(reopened.provenance.symbolInput, provenance.symbolInput)
        XCTAssertEqual(reopened.report.image.sliceSHA256, try AuditReport.decode(raw).image.sliceSHA256)
    }

    func testDuplicatesRequireExactBytesAndProvenance() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportLibrary(root: root)
        let raw = try data(); let origin = LibraryProvenance(sourceLabel: "One")
        let first = try await store.keep(raw, provenance: origin)
        let duplicate = try await store.keep(raw, provenance: origin)
        let whitespace = try await store.keep(raw + Data("\n".utf8), provenance: origin)
        let otherOrigin = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "Two"))
        XCTAssertEqual(first, duplicate)
        XCTAssertNotEqual(first, whitespace)
        XCTAssertNotEqual(first, otherOrigin)
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 3)
    }

    func testCorruptAndMissingReportsStayVisibleAndCannotLoad() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportLibrary(root: root); let raw = try data()
        let corrupt = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "Corrupt"))
        let missing = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "Missing"))
        try (raw + Data(" ".utf8)).write(to: root.appendingPathComponent("\(corrupt.uuidString)/report.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(missing.uuidString)/report.json"))
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.issue != nil })
        for id in [corrupt, missing] {
            do { _ = try await store.load(id); XCTFail("Damaged report loaded") } catch {}
        }
    }

    func testEntryAndByteLimitsKeepExistingSnapshot() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try data()
        let store = ReportLibrary(root: root, maximumEntries: 1, maximumTotalBytes: raw.count)
        let id = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "One"))
        do { _ = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "Two")); XCTFail("Limit bypassed") } catch {}
        let kept = try await store.load(id)
        XCTAssertEqual(kept.data, raw)
        let tiny = ReportLibrary(root: root.appendingPathComponent("tiny"), maximumTotalBytes: raw.count - 1)
        do { _ = try await tiny.keep(raw, provenance: LibraryProvenance(sourceLabel: "One")); XCTFail("Byte limit bypassed") } catch {}
    }

    func testInvalidReportAndStorageFailurePublishNothing() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ReportLibrary(root: root)
        do { _ = try await store.keep(Data("{}".utf8), provenance: LibraryProvenance(sourceLabel: "Invalid")); XCTFail("Invalid report stored") } catch {}
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        do { _ = try await ReportLibrary(root: blocked).keep(data(), provenance: LibraryProvenance(sourceLabel: "No directory")); XCTFail("Storage failure ignored") } catch {}
    }

    func testSymlinkEntryCannotReadExternalReport() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json"); let raw = try data()
        try raw.write(to: outside)
        let store = ReportLibrary(root: root)
        let id = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: "One"))
        let snapshot = root.appendingPathComponent("\(id.uuidString)/report.json")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: outside)
        do { _ = try await store.load(id); XCTFail("Symlink followed") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), raw)
    }

    func testRemoveMovesOnlyOwnedCopyToTrash() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let raw = try data(); let original = root.appendingPathComponent("original.json")
        try raw.write(to: original)
        let store = ReportLibrary(root: root)
        let id = try await store.keep(raw, provenance: LibraryProvenance(sourceLabel: original.path))
        try await store.remove(id)
        let entries = try await store.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), raw)
    }
}
