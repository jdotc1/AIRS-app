import Foundation
import XCTest
@testable import AIRSCore

private actor ResumeCalls {
    var paths: [URL] = []
    func add(_ path: URL) { paths.append(path) }
    func values() -> [URL] { paths }
}

final class BatchHistoryTests: XCTestCase {
    private func fixture() throws -> (URL, [URL], Data) {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("build/batch-history-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = ["first.input", "second.input", "third.input"].map { root.appendingPathComponent($0) }
        for input in inputs { try Data("Owned input data, never executed".utf8).write(to: input) }
        let raw = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures")))
        return (root, inputs, raw)
    }

    private func stopped(_ inputs: [URL], raw: Data, history: BatchHistory) async throws -> ImageBatchSnapshot {
        try await ImageBatchRunner().run(inputs: inputs, audit: { input in
            if input == inputs[1] { throw CancellationError() }
            return raw
        }, retain: { _, _ in UUID() }, checkpoint: { try await history.save($0) })
    }

    func testNewStoreResumesOnlyRemainingItemsAndPreservesOutcomeHistory() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history"); let store = BatchHistory(root: url)
        let first = try await stopped(inputs, raw: raw, history: store)
        XCTAssertEqual(first.items.map(\.status), [.completed, .cancelled, .notStarted])
        let recovered = try await BatchHistory(root: url).load(first.id)
        let calls = ResumeCalls()
        let result = try await ImageBatchRunner().run(inputs: inputs, resuming: recovered, audit: { input in
            await calls.add(input); return raw
        }, retain: { _, _ in UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertEqual(result.id, first.id)
        XCTAssertNotEqual(result.executionID, first.executionID)
        XCTAssertEqual(result.items.map(\.id), first.items.map(\.id))
        XCTAssertEqual(result.items[0].retainedReportID, first.items[0].retainedReportID)
        XCTAssertEqual(result.items.map(\.status), [.completed, .completed, .completed])
        let paths = await calls.values()
        XCTAssertEqual(paths, Array(inputs.suffix(2)))
        XCTAssertEqual(result.items[1].attempts.map(\.status), [.cancelled])
        XCTAssertEqual(result.items[2].attempts.map(\.status), [.notStarted])
        let latest = try await BatchHistory(root: url).load(first.id)
        XCTAssertEqual(latest.checkpointRevision, result.checkpointRevision)
    }

    func testCompletedBytesCheckpointPrecedesRetentionAndSurvivesNewStore() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history"); let store = BatchHistory(root: url)
        let calls = ResumeCalls()
        let result = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, input in
            let inventory = try await store.entries()
            let durable = try await BatchHistory(root: url).load(XCTUnwrap(inventory.first?.id))
            XCTAssertEqual(durable.items[0].unretainedData, raw)
            await calls.add(input); throw ReportError.invalidContents("Owned library unavailable")
        }, checkpoint: { try await store.save($0) })
        let recovered = try await BatchHistory(root: url).load(result.id)
        XCTAssertEqual(recovered.items.map(\.status), [.completed, .notStarted, .notStarted])
        XCTAssertEqual(recovered.items[0].unretainedData, raw)
        XCTAssertTrue(recovered.hasUnretainedReports)
        XCTAssertNil(recovered.persistenceError)
        let paths = await calls.values()
        XCTAssertEqual(paths, [inputs[0]])
        do {
            _ = try await ImageBatchRunner().run(inputs: inputs, resuming: recovered, audit: { _ in XCTFail("Completed report replayed"); return raw }, retain: { _, _ in UUID() })
            XCTFail("Pending raw report did not block resume")
        } catch {}
    }

    func testChangedInputFailsBeforeAuditAndPriorFailuresAreNotRetried() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BatchHistory(root: root.appendingPathComponent("history"))
        var saved = try await stopped(inputs, raw: raw, history: store)
        saved.items[2].status = .failed
        saved.items[2].message = "Original failure kept"
        saved.checkpointRevision = try await store.save(saved)
        try Data("Changed queued input".utf8).write(to: inputs[1])
        let calls = ResumeCalls()
        let result = try await ImageBatchRunner().run(inputs: inputs, resuming: saved, audit: { input in
            await calls.add(input); return raw
        }, retain: { _, _ in UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertEqual(result.items.map(\.status), [.completed, .failed, .failed])
        XCTAssertTrue(result.items[1].message.contains("changed"))
        XCTAssertEqual(result.items[2].message, "Original failure kept")
        let paths = await calls.values()
        XCTAssertTrue(paths.isEmpty)
    }

    func testChangedContextAndUnsettledRunningCheckpointRejectReplay() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BatchHistory(root: root.appendingPathComponent("history"))
        let saved = try await stopped(inputs, raw: raw, history: store)
        var active = saved; active.items[1].status = .running; active.settled = false
        for candidate in [saved, active] {
            do {
                let context = candidate.settled ? BatchExecutionContext(policy: "changed", files: []) : nil
                _ = try await ImageBatchRunner().run(inputs: inputs, resuming: candidate, context: context,
                    audit: { _ in XCTFail("Unsafe resume executed"); return raw }, retain: { _, _ in UUID() })
                XCTFail("Unsafe context/ownership admitted")
            } catch {}
        }
    }

    func testLeaseAndRevisionRejectConcurrentAndStaleMutations() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history")
        let store = BatchHistory(root: url); let other = BatchHistory(root: url)
        let saved = try await stopped(inputs, raw: raw, history: store)
        try await store.acquire(saved.id, revision: saved.checkpointRevision)
        do { try await other.acquire(saved.id); XCTFail("Concurrent ownership admitted") } catch {}
        await store.release(saved.id)
        var changed = saved
        changed.items[1].message = "Newer same-generation update"
        changed.checkpointRevision = try await store.save(changed)
        do { try await other.save(saved); XCTFail("Stale same-generation save accepted") } catch {}
        let kept = try await other.load(saved.id)
        XCTAssertEqual(kept.items[1].message, changed.items[1].message)
    }

    func testCorruptionAndPendingSpoolTamperingDoNotDisappearOrReplay() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history"); let store = BatchHistory(root: url)
        let result = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in
            throw ReportError.invalidContents("Owned failure")
        }, checkpoint: { try await store.save($0) })
        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.unretainedData, raw)
        let pending = url.appendingPathComponent("\(result.id.uuidString)/\(item.id.uuidString).report.json")
        try (raw + Data(" ".utf8)).write(to: pending)
        do { _ = try await store.load(result.id); XCTFail("Tampered bytes admitted") } catch {}
        try Data("{}".utf8).write(to: url.appendingPathComponent("\(result.id.uuidString)/checkpoint.json"))
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries[0].issue)
    }

    func testSmallHistoryAndRecoveryBudgetsStopWithoutLosingCurrentBytes() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = BatchHistory(root: root.appendingPathComponent("history"), maximumBatches: 1,
                                 maximumRecoveryBytes: raw.count - 1)
        let snapshot = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertNotNil(snapshot.persistenceError)
        XCTAssertEqual(snapshot.items[0].unretainedData, raw)
        XCTAssertEqual(snapshot.items.map(\.status), [.completed, .notStarted, .notStarted])
        do { try await store.acquire(UUID()); XCTFail("History entry limit bypassed") } catch {}
    }

    func testAppPrincipalAndEngineSourceMetadataChangesInvalidateContext() throws {
        let (root, inputs, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Owned.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Owned")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Owned image data".utf8).write(to: executable)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Owned"], format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let before = try BatchInputIdentity.capture(bundle)
        try Data("Changed owned image data".utf8).write(to: executable)
        XCTAssertNotEqual(before, try BatchInputIdentity.capture(bundle))
        let source = root.appendingPathComponent("src/airs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let module = source.appendingPathComponent("owned.py")
        try Data("owned = 1".utf8).write(to: module)
        let config = EngineConfiguration(pythonExecutable: inputs[0], bootstrap: inputs[1])
        let context = try BatchExecutionContext.capture(config)
        try Data("owned = 200".utf8).write(to: module)
        XCTAssertNotEqual(context, try BatchExecutionContext.capture(config))
    }

    func testDifferentStoresCannotRacePastGlobalEntryLimit() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in throw CancellationError() }, retain: { _, _ in UUID() })
        let second = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in UUID() })
        let url = root.appendingPathComponent("history")
        let a = BatchHistory(root: url, maximumBatches: 1)
        let b = BatchHistory(root: url, maximumBatches: 1)
        let one = Task { do { try await a.save(first); return true } catch { return false } }
        let two = Task { do { try await b.save(second); return true } catch { return false } }
        let successes = await [one.value, two.value].filter { $0 }.count
        XCTAssertEqual(successes, 1)
        let entries = try await a.entries()
        XCTAssertEqual(entries.count, 1)
    }
}
