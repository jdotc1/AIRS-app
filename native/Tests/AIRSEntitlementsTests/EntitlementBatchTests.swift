import Foundation
import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

private actor TestReader: SnapshotReading {
    var calls: [String] = []
    let failures: Set<String>
    let wrongArchitecture: Bool
    init(failures: Set<String> = [], wrongArchitecture: Bool = false) {
        self.failures = failures; self.wrongArchitecture = wrongArchitecture
    }
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls.append(url.lastPathComponent)
        if failures.contains(url.lastPathComponent) { throw CocoaError(.fileReadCorruptFile) }
        let pair = ExampleSnapshots.pair(architecture: wrongArchitecture ? .x86_64 : architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

private actor RetainedBytes {
    var values: [Data] = []
    func keep(_ data: Data) -> UUID { values.append(data); return UUID() }
}

private actor ReadGate: SnapshotReading {
    private var continuation: CheckedContinuation<EntitlementSnapshot, Error>?
    private var start: CheckedContinuation<Void, Never>?
    var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation {
            continuation = $0; start?.resume(); start = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { start = $0 }
    }
    func finish() { continuation?.resume(returning: ExampleSnapshots.pair(architecture: .arm64).previous); continuation = nil }
}

private actor CommitGate {
    private var continuation: CheckedContinuation<UUID, Never>?
    private var start: CheckedContinuation<Void, Never>?
    let retainedID = UUID()
    func keep(_ data: Data) async -> UUID {
        await withCheckedContinuation { continuation = $0; start?.resume(); start = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { start = $0 }
    }
    func finish() { continuation?.resume(returning: retainedID); continuation = nil }
}

final class EntitlementBatchTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-batch-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent("\(name).app")
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("owned bytes, never executed".utf8).write(to: macOS.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    private func pair(_ suffix: String, in root: URL) throws -> EntitlementBatchPair {
        try .init(previous: app("Previous\(suffix)", in: root), current: app("Current\(suffix)", in: root), architecture: .arm64)
    }

    func testExplicitPairOrderDuplicateAndSharedBaselineKeepCompleteReports() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try pair("1", in: root)
        let two = EntitlementBatchPair(previous: one.previous, current: try app("Current2", in: root), architecture: .arm64)
        let duplicate = EntitlementBatchPair(previous: one.previous, current: one.current, architecture: .arm64)
        let reader = TestReader(); let retained = RetainedBytes()
        let result = try await EntitlementBatchRunner().run(pairs: [one, duplicate, two], reader: reader,
            retain: { await retained.keep($0) })
        XCTAssertEqual(result.rows.map(\.status), [.completed, .duplicate, .completed])
        XCTAssertEqual(result.rows.map(\.id), [one.id, duplicate.id, two.id])
        let calls = await reader.calls
        XCTAssertEqual(calls, ["Previous1.app", "Current1.app", "Previous1.app", "Current2.app"])
        let reports = await retained.values
        XCTAssertEqual(reports.count, 2)
        for data in reports {
            let saved = try SavedReport.parse(data)
            let expected = ExampleSnapshots.pair(architecture: .arm64)
            XCTAssertEqual(saved.previous.entitlements, expected.previous.entitlements)
            XCTAssertEqual(saved.current.entitlements, expected.current.entitlements)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))
        }
        XCTAssertTrue(result.settled); XCTAssertFalse(result.hasUnretainedReport)
    }

    func testFailedPreviousSkipsCurrentAndNextPairStillRuns() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = try [pair("1", in: root), pair("2", in: root)]
        let reader = TestReader(failures: ["Previous1.app"])
        let result = try await EntitlementBatchRunner().run(pairs: pairs, reader: reader, retain: { _ in UUID() })
        XCTAssertEqual(result.rows.map(\.status), [.failed, .completed])
        XCTAssertNil(result.rows[0].changedCount)
        let calls = await reader.calls
        XCTAssertEqual(calls, ["Previous1.app", "Previous2.app", "Current2.app"])
    }

    func testRequestedArchitectureIsCheckedBeforeCurrentRead() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = TestReader(wrongArchitecture: true)
        let result = try await EntitlementBatchRunner().run(pairs: [pair("1", in: root)], reader: reader,
            retain: { _ in XCTFail("Wrong architecture retained"); return UUID() })
        XCTAssertEqual(result.rows.first?.status, .failed)
        let calls = await reader.calls; XCTAssertEqual(calls, ["Previous1.app"])
    }

    func testCancelledReadSettlesWithoutPublishingAndRunnerRejectsConcurrentRun() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = try [pair("1", in: root), pair("2", in: root)]
        let reader = ReadGate(); let runner = EntitlementBatchRunner()
        let task = Task { try await runner.run(pairs: pairs, reader: reader, retain: { _ in XCTFail("Cancelled read retained"); return UUID() }) }
        await reader.started()
        do { _ = try await runner.run(pairs: pairs, reader: reader, retain: { _ in UUID() }); XCTFail("Concurrent run accepted") }
        catch { XCTAssertTrue(error is EntitlementBatchError) }
        task.cancel(); await reader.finish()
        let result = try await task.value
        XCTAssertEqual(result.rows.map(\.status), [.cancelled, .notStarted])
        XCTAssertTrue(result.cancelled); XCTAssertTrue(result.settled)
        let calls = await reader.calls; XCTAssertEqual(calls, 1)
    }

    func testCancellationDuringCommitPreservesSavedResultAndStopsNextPair() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = try [pair("1", in: root), pair("2", in: root)]
        let gate = CommitGate(); let reader = TestReader()
        let task = Task { try await EntitlementBatchRunner().run(pairs: pairs, reader: reader, retain: { await gate.keep($0) }) }
        await gate.started(); task.cancel(); await gate.finish()
        let result = try await task.value
        XCTAssertEqual(result.rows.map(\.status), [.completed, .notStarted])
        XCTAssertNotNil(result.rows[0].retainedReportID)
        XCTAssertNil(result.rows[0].unretainedData)
        XCTAssertTrue(result.cancelled)
        let calls = await reader.calls; XCTAssertEqual(calls.count, 2)
    }

    func testRetentionFailurePreservesOneCompleteReportAndStopsQueue() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = try [pair("1", in: root), pair("2", in: root)]
        let reader = TestReader()
        let result = try await EntitlementBatchRunner().run(pairs: pairs, reader: reader,
            retain: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(result.rows.map(\.status), [.completed, .notStarted])
        XCTAssertTrue(result.hasUnretainedReport)
        XCTAssertNil(result.rows[0].retainedReportID)
        _ = try SavedReport.parse(XCTUnwrap(result.rows[0].unretainedData))
        let calls = await reader.calls; XCTAssertEqual(calls.count, 2)
    }

    func testAdmissionChangeRejectsPairWithoutReadingIt() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pair = try pair("1", in: root); let reader = TestReader()
        let result = try await EntitlementBatchRunner().run(pairs: [pair], reader: reader,
            retain: { _ in XCTFail("Changed input retained"); return UUID() },
            progress: { value in
                if value.rows.first?.status == .running {
                    try? Data("changed".utf8).write(to: pair.current.appendingPathComponent("Contents/MacOS/fixture"))
                }
            })
        XCTAssertEqual(result.rows.first?.status, .failed)
        let calls = await reader.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testAggregateBudgetStopsBeforeReadingNextPair() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pairs = try [pair("1", in: root), pair("2", in: root)]
        let sample = ExampleSnapshots.pair(architecture: .arm64)
        let bytes = try EntitlementDiffCore.ComparisonReport(previous: sample.previous, current: sample.current).jsonData()
        let reader = TestReader(); let retained = RetainedBytes()
        let result = try await EntitlementBatchRunner(maximumReportBytes: bytes.count, maximumTotalBytes: bytes.count)
            .run(pairs: pairs, reader: reader, retain: { await retained.keep($0) })
        XCTAssertEqual(result.rows.map(\.status), [.completed, .notStarted])
        XCTAssertNotNil(result.rows[0].retainedReportID)
        let calls = await reader.calls; XCTAssertEqual(calls.count, 2)
        let saved = await retained.values; XCTAssertEqual(saved, [bytes])
    }

    func testReportLimitsAndInvalidQueueFailWithoutTruncation() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let pair = try pair("1", in: root)
        let runner = EntitlementBatchRunner(maximumReportBytes: 1, maximumTotalBytes: 1)
        let result = try await runner.run(pairs: [pair], reader: TestReader(), retain: { _ in XCTFail("Oversize retained"); return UUID() })
        XCTAssertEqual(result.rows.first?.status, .failed)
        XCTAssertNil(result.rows.first?.changedCount); XCTAssertNil(result.rows.first?.unretainedData)
        for invalid in [[], [pair, pair], Array(repeating: pair, count: 17)] {
            do { _ = try await runner.run(pairs: invalid, reader: TestReader(), retain: { _ in UUID() }); XCTFail("Invalid queue accepted") } catch {}
        }
    }
}
