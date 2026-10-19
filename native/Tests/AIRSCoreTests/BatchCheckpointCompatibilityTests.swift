import CryptoKit
import Foundation
import XCTest
@testable import AIRSCore

/// The pre-extraction version-1 envelope, independent of BatchCheckpointStore.
private struct LegacyAuditCheckpoint: Codable {
    let version: Int
    let updatedAt: Date
    let snapshot: ImageBatchSnapshot
    let pendingReports: [String: String]
}

final class BatchCheckpointCompatibilityTests: XCTestCase {
    func testVersionOneAuditEnvelopeAndPendingReportSurviveGenericStoreExtraction() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/batch-checkpoint-compatibility/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("owned.input")
        try Data("Owned bytes, never executed".utf8).write(to: input)
        let raw = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures")))
        var original = try await ImageBatchRunner().run(inputs: [input], audit: { _ in raw },
            retain: { _, _ in throw ReportError.invalidContents("Owned retention failure") })
        original.checkpointRevision = UUID()
        let itemID = try XCTUnwrap(original.items.first?.id)
        let folder = root.appendingPathComponent("history/\(original.id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spool = folder.appendingPathComponent("\(itemID.uuidString).report.json")
        try raw.write(to: spool)
        let digest = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = LegacyAuditCheckpoint(version: 1, updatedAt: timestamp, snapshot: original,
                                           pendingReports: [itemID.uuidString: digest])
        let manifest = folder.appendingPathComponent("checkpoint.json")
        try JSONEncoder().encode(legacy).write(to: manifest)

        let store = BatchHistory(root: root.appendingPathComponent("history"))
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.updatedAt, timestamp)
        XCTAssertNil(entries.first?.issue)
        let metadata = try await store.metadata(original.id)
        XCTAssertNil(metadata.items[0].unretainedData)
        var reopened = try await store.load(original.id)
        XCTAssertEqual(reopened.id, original.id)
        XCTAssertEqual(reopened.executionID, original.executionID)
        XCTAssertEqual(reopened.checkpointRevision, original.checkpointRevision)
        XCTAssertEqual(reopened.items[0].unretainedData, raw)
        XCTAssertEqual(reopened.items[0].inputIdentity, original.items[0].inputIdentity)
        XCTAssertEqual(reopened.items[0].reportByteCount, raw.count)
        XCTAssertEqual(reopened.items[0].status, .completed)

        let retainedID = UUID()
        reopened.items[0].retainedReportID = retainedID
        reopened.items[0].unretainedData = nil
        reopened.checkpointRevision = try await store.save(reopened)
        let legacyReader = try JSONDecoder().decode(LegacyAuditCheckpoint.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(legacyReader.version, 1)
        XCTAssertEqual(legacyReader.snapshot.id, original.id)
        XCTAssertEqual(legacyReader.snapshot.items[0].retainedReportID, retainedID)
        XCTAssertEqual(legacyReader.snapshot.checkpointRevision, reopened.checkpointRevision)
        XCTAssertTrue(legacyReader.pendingReports.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }
}
