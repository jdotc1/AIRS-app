import Darwin
import Foundation
import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements

private actor RecoveryReader: SnapshotReading {
    private(set) var calls: [String] = []
    let cancelAt: String?
    init(cancelAt: String? = nil) { self.cancelAt = cancelAt }
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls.append(url.lastPathComponent)
        if url.lastPathComponent == cancelAt { throw CancellationError() }
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

final class EntitlementBatchRecoveryTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-recovery-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(in root: URL) throws -> ([EntitlementBatchPair], EntitlementReaderContext) {
        func app(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name).app")
            let executable = url.appendingPathComponent("Contents/MacOS/fixture")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Owned data; never executed".utf8).write(to: executable)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let pairs = try (1...3).map { number in
            EntitlementBatchPair(previous: try app("Previous\(number)"), current: try app("Current\(number)"), architecture: .arm64)
        }
        let reader = root.appendingPathComponent("reader-context.input")
        try Data("Owned reader identity; never executed".utf8).write(to: reader)
        return (pairs, try EntitlementReaderContext.capture(executable: reader))
    }

    private func stopped(_ pairs: [EntitlementBatchPair], context: EntitlementReaderContext,
                         store: EntitlementBatchRecovery) async throws -> EntitlementBatchCheckpoint {
        try await EntitlementBatchRunner().runRecoverable(pairs: pairs, reader: RecoveryReader(cancelAt: "Previous2.app"),
            context: context, retain: { _ in UUID() }, checkpoint: { try await store.save($0) })
    }

    func testExplicitResumeKeepsCompletedPairAndReadsOnlyRemainingPairs() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        let first = try await stopped(pairs, context: context, store: store)
        XCTAssertEqual(first.result.rows.map(\.status), [.completed, .cancelled, .notStarted])
        let recovered = try await EntitlementBatchRecovery(root: store.storageRoot).load(first.id)
        let reader = RecoveryReader()
        let resumed = try await EntitlementBatchRunner().runRecoverable(pairs: pairs, reader: reader,
            context: context, resuming: recovered, retain: { _ in UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertNotEqual(resumed.executionID, first.executionID)
        XCTAssertEqual(resumed.previousExecutionID, first.executionID)
        XCTAssertEqual(resumed.result.rows.map(\.id), pairs.map(\.id))
        XCTAssertEqual(resumed.result.rows.map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(resumed.result.rows[0].retainedReportID, first.result.rows[0].retainedReportID)
        XCTAssertEqual(resumed.admissions[1].attempts.map(\.status), [.cancelled])
        XCTAssertEqual(resumed.admissions[2].attempts.map(\.status), [.notStarted])
        let calls = await reader.calls
        XCTAssertEqual(calls, ["Previous2.app", "Current2.app", "Previous3.app", "Current3.app"])
    }

    func testChangedInputRefusedBeforeReadAndPriorFailureIsPreserved() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        var first = try await stopped(pairs, context: context, store: store)
        first.result.rows[2].status = .failed
        first.result.rows[2].message = "Original failure is terminal"
        first.checkpointRevision = try await store.save(first)
        try Data("Changed principal executable identity".utf8).write(to: pairs[1].current.appendingPathComponent("Contents/MacOS/fixture"))
        let reader = RecoveryReader()
        let resumed = try await EntitlementBatchRunner().runRecoverable(pairs: pairs, reader: reader,
            context: context, resuming: first, retain: { _ in XCTFail("Changed app retained"); return UUID() },
            checkpoint: { try await store.save($0) })
        XCTAssertEqual(resumed.result.rows.map(\.status), [.completed, .failed, .failed])
        XCTAssertTrue(resumed.result.rows[1].message.contains("changed"))
        XCTAssertEqual(resumed.result.rows[2].message, "Original failure is terminal")
        let calls = await reader.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testChangedReaderContextAndAttemptLimitRejectResumeBeforeReading() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        let first = try await stopped(pairs, context: context, store: store)
        let readerURL = root.appendingPathComponent("reader-context.input")
        try Data("A changed reader identity with a different byte count".utf8).write(to: readerURL)
        let changed = try EntitlementReaderContext.capture(executable: readerURL)
        var exhausted = first
        exhausted.admissions[1].attempts = (0..<EntitlementBatchCheckpoint.maximumAttempts).map { _ in
            .init(status: .cancelled, message: "Earlier bounded attempt", date: Date())
        }
        let reader = RecoveryReader()
        for (candidate, selectedContext) in [(first, changed), (exhausted, context)] {
            do {
                _ = try await EntitlementBatchRunner().runRecoverable(pairs: pairs, reader: reader,
                    context: selectedContext, resuming: candidate, retain: { _ in UUID() }, checkpoint: { _ in nil })
                XCTFail("Unsafe resume admitted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Resume requires")) }
        }
        let calls = await reader.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testLeaseAndRevisionRejectConcurrentRecoveryAndStaleSave() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        let first = try await stopped(pairs, context: context, store: store)
        let other = EntitlementBatchRecovery(root: store.storageRoot)
        try await store.acquire(first.id, revision: first.checkpointRevision)
        do { _ = try await other.recover(first); XCTFail("Concurrent recovery accepted") } catch {}
        await store.release(first.id)
        var newer = first; newer.result.rows[1].message = "Newer checkpoint"
        newer.checkpointRevision = try await other.save(newer)
        do { _ = try await store.save(first); XCTFail("Stale save accepted") } catch {}
        do { _ = try await store.recover(first); XCTFail("Stale recovery accepted") } catch {}
        let loaded = try await store.load(first.id)
        XCTAssertEqual(loaded.result.rows[1].message, "Newer checkpoint")
        XCTAssertEqual(loaded.checkpointRevision, newer.checkpointRevision)
    }

    func testPendingReportBudgetStopsQueueAndPreservesCompleteBytes() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"), maximumBatches: 1, maximumRecoveryBytes: 1)
        let reader = RecoveryReader()
        let result = try await EntitlementBatchRunner().runRecoverable(pairs: pairs, reader: reader, context: context,
            retain: { _ in XCTFail("Uncheckpointed report retained"); return UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertNotNil(result.persistenceError)
        XCTAssertEqual(result.result.rows.map(\.status), [.completed, .notStarted, .notStarted])
        _ = try SavedReport.parse(XCTUnwrap(result.result.rows[0].unretainedData))
        let calls = await reader.calls; XCTAssertEqual(calls.count, 2)
        do { try await store.acquire(UUID()); XCTFail("Entry budget bypassed") } catch {}
    }

    /// A separate test process exits without unwinding while it owns the lease.
    func testAbruptExitWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIRS_RECOVERY_CRASH_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        let (pairs, context) = try fixture(in: root)
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        let id = UUID()
        let afterLibrary = ProcessInfo.processInfo.environment["AIRS_RECOVERY_CRASH_POINT"] == "library"
        let library = SnapshotLibrary<SavedReport>(root: root.appendingPathComponent("library"),
            maximumReportBytes: SavedReport.maximumBytes, decode: { try SavedReport.parse($0) })
        try await store.acquire(id)
        _ = try await EntitlementBatchRunner().runRecoverable(pairs: pairs, id: id, reader: RecoveryReader(), context: context,
            retain: { data in
                _ = try await library.keep(data, provenance: LibraryProvenance(sourceLabel: "Entitlement comparison"))
                Darwin._exit(74)
            }, checkpoint: { state in
                let revision = try await store.save(state)
                if !afterLibrary && state.result.rows[0].unretainedData != nil { Darwin._exit(73) }
                return revision
            })
        XCTFail("Crash boundary was never reached")
    }

    func testAbruptExitReleasesLeaseAndRecoversCompleteReportWithoutReplay() async throws {
        try await verifyAbruptExit(afterLibrary: false)
    }

    func testAbruptExitAfterLibraryPublicationRecoversSameReportWithoutDuplicate() async throws {
        try await verifyAbruptExit(afterLibrary: true)
    }

    private func verifyAbruptExit(afterLibrary: Bool) async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("crash-worker.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let log = try FileHandle(forWritingTo: output); defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "AIRSEntitlementsTests.EntitlementBatchRecoveryTests/testAbruptExitWorker",
                           Bundle(for: EntitlementBatchRecoveryTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["AIRS_RECOVERY_CRASH_ROOT"] = root.path
        environment["AIRS_RECOVERY_CRASH_POINT"] = afterLibrary ? "library" : "pending"
        child.environment = environment
        child.standardOutput = log; child.standardError = log
        try child.run()
        let deadline = Date().addingTimeInterval(20)
        while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if child.isRunning { child.terminate(); XCTFail("Crash worker timed out"); return }
        let expectedExit: Int32 = afterLibrary ? 74 : 73
        let workerOutput = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        XCTAssertEqual(child.terminationStatus, expectedExit, workerOutput)
        guard child.terminationStatus == expectedExit else { return }
        let store = EntitlementBatchRecovery(root: root.appendingPathComponent("history"))
        let entries = try await store.entries()
        XCTAssertEqual(entries.count, 1)
        let metadata = try XCTUnwrap(entries.first?.snapshot)
        XCTAssertFalse(metadata.result.settled)
        let recovered = try await store.recover(metadata)
        XCTAssertEqual(recovered.result.rows.map(\.status), [.completed, .notStarted, .notStarted])
        let raw = try XCTUnwrap(recovered.result.rows[0].unretainedData)
        _ = try SavedReport.parse(raw)
        let reader = RecoveryReader()
        do {
            _ = try await EntitlementBatchRunner().runRecoverable(pairs: recovered.result.rows.map(\.pair), reader: reader,
                context: XCTUnwrap(recovered.context), resuming: recovered, retain: { _ in UUID() }, checkpoint: { _ in nil })
            XCTFail("Pending complete report permitted replay")
        } catch {}
        let library = SnapshotLibrary<SavedReport>(root: root.appendingPathComponent("library"),
            maximumReportBytes: SavedReport.maximumBytes, decode: { try SavedReport.parse($0) })
        let before = try await library.entries { $0.previous.sourceName }
        XCTAssertEqual(before.count, afterLibrary ? 1 : 0)
        let reportID = try await library.keep(raw, provenance: LibraryProvenance(sourceLabel: "Entitlement comparison"))
        if afterLibrary { XCTAssertEqual(reportID, before.first?.id) }
        let after = try await library.entries { $0.previous.sourceName }
        XCTAssertEqual(after.count, 1)
        let saved = try await library.load(reportID)
        XCTAssertEqual(saved.data, raw)
        var retained = recovered
        retained.result.rows[0].retainedReportID = reportID
        retained.result.rows[0].unretainedData = nil
        retained.checkpointRevision = try await store.save(retained)
        let resumed = try await EntitlementBatchRunner().runRecoverable(pairs: retained.result.rows.map(\.pair), reader: reader,
            context: XCTUnwrap(retained.context), resuming: retained, retain: { _ in UUID() }, checkpoint: { try await store.save($0) })
        XCTAssertEqual(resumed.result.rows.map(\.status), [.completed, .completed, .completed])
        XCTAssertEqual(resumed.result.rows[0].retainedReportID, reportID)
        let calls = await reader.calls
        XCTAssertEqual(calls, ["Previous2.app", "Current2.app", "Previous3.app", "Current3.app"])
        let spool = store.storageRoot.appendingPathComponent("\(retained.id.uuidString)/\(retained.result.rows[0].id.uuidString).report.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }
}
