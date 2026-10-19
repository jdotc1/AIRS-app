import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

final class EntitlementBatchHistoryTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-history-evidence/core/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func result() -> EntitlementBatchResult {
        let rows: [EntitlementBatchRow] = [.completed, .failed, .cancelled, .notStarted, .duplicate].map { status in
            .init(pair: .init(previous: URL(fileURLWithPath: "/missing/Previous.app"),
                             current: URL(fileURLWithPath: "/missing/Current.app"), architecture: .arm64),
                  status: status, message: "Original \(status.rawValue) outcome",
                  changedCount: status == .completed ? 1 : nil, unchangedCount: status == .completed ? 0 : nil,
                  retainedReportID: status == .completed ? UUID() : nil)
        }
        return .init(id: UUID(), rows: rows, settled: true, cancelled: true)
    }

    func testMixedOutcomesPersistExactlyAcrossInstancesWithoutSourceAppsAndDeduplicate() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let original = result()
        let record = try EntitlementBatchRecord(result: original, finishedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try record.data()
        let history = EntitlementBatchHistory(root: root)
        let id = try await history.keep(data)
        let duplicate = try await history.keep(data); XCTAssertEqual(id, duplicate)
        let reopened = EntitlementBatchHistory(root: root)
        let loaded = try await reopened.load(id)
        XCTAssertEqual(try loaded.data(), data)
        XCTAssertEqual(loaded.result.rows.map(\.status), original.rows.map(\.status))
        XCTAssertEqual(loaded.result.rows.map(\.id), original.rows.map(\.id))
        let entries = try await reopened.entries()
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries.first?.summary?.pairs, 5)
        XCTAssertEqual(entries.first?.summary?.completed, 1); XCTAssertEqual(entries.first?.summary?.failed, 1)
    }

    func testManifestRejectsUnsettledPendingAmbiguousAndInvalidRows() throws {
        var candidate = result(); candidate.settled = false
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[0].unretainedData = Data([1])
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[0].retainedReportID = nil
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[1].changedCount = 0
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[1].status = .running
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows.append(candidate.rows[0])
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[0].changedCount = -1
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        candidate = result(); candidate.rows[0].exportedReportURL = URL(string: "https://example.invalid/report.json")
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
        let valid = try EntitlementBatchRecord(result: result()).data()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["version"] = 2
        XCTAssertThrowsError(try EntitlementBatchRecord.decode(JSONSerialization.data(withJSONObject: object)))
        candidate = result(); candidate.rows[0].message = String(repeating: "x", count: EntitlementBatchRecord.maximumBytes)
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate).data())
    }

    func testCapacityAndCorruptHistoryStayExplicit() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let history = EntitlementBatchHistory(root: root, maximumEntries: 1)
        let id = try await history.keep(EntitlementBatchRecord(result: result()).data())
        do { _ = try await history.keep(EntitlementBatchRecord(result: result()).data()); XCTFail("capacity") }
        catch { XCTAssertTrue(error.localizedDescription.contains("full")) }
        let file = root.appendingPathComponent(id.uuidString).appendingPathComponent("report.json")
        try Data("changed".utf8).write(to: file)
        let entries = try await history.entries()
        XCTAssertEqual(entries.count, 1); XCTAssertNil(entries[0].summary); XCTAssertNotNil(entries[0].issue)
        do { _ = try await history.load(id); XCTFail("corruption") } catch {}
    }

    func testExportReferenceRequiresExactCompleteBytesAndValidLocalDestination() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let data = try EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current).jsonData()
        let url = root.appendingPathComponent("export.json")
        try data.write(to: url)
        var candidate = result()
        candidate.rows[0].retainedReportID = nil
        candidate.rows[0].exportedReportURL = url
        candidate.rows[0].exportedReportSHA256 = EntitlementBatchHistory.reportDigest(data)
        let record = try EntitlementBatchRecord(result: candidate)
        let loaded = try EntitlementBatchRecord.decode(record.data())
        let digest = try XCTUnwrap(loaded.result.rows[0].exportedReportSHA256)
        _ = try EntitlementBatchHistory.readExport(url, expectedDigest: digest)
        let replacement = try EntitlementDiffCore.ComparisonReport(previous: pair.current, current: pair.previous).jsonData()
        try replacement.write(to: url)
        XCTAssertThrowsError(try EntitlementBatchHistory.readExport(url, expectedDigest: digest))
        candidate.rows[0].exportedReportSHA256 = String(repeating: "Z", count: 64)
        XCTAssertThrowsError(try EntitlementBatchRecord(result: candidate))
    }
}
