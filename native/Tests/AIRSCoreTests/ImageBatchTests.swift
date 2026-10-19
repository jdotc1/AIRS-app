import Foundation
import XCTest
@testable import AIRSCore

private actor BatchProbe {
    var names: [String] = []
    var active = 0
    var peak = 0
    var retained = 0
    func begin(_ name: String) { names.append(name); active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
    func nextRetention() -> Int { retained += 1; return retained }
    func retentionCount() -> Int { retained }
    func state() -> ([String], Int, Int) { (names, active, peak) }
}

private actor BatchGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class ImageBatchTests: XCTestCase {
    private func fixture() throws -> (URL, [URL], Data) {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("build/batch-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputs = ["first image", "second image", "third image"].map { root.appendingPathComponent($0) }
        for input in inputs { try Data("Owned test input; never executed".utf8).write(to: input) }
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "audit-v1", withExtension: "json", subdirectory: "Fixtures")))
        return (root, inputs, data)
    }
    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned batch gate did not open")
    }

    func testEveryInputHasOutcomeAndSuccessfulRawReportsPersistSerially() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = ReportLibrary(root: root.appendingPathComponent("library"))
        let probe = BatchProbe()
        let invalidDirectory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: false)
        let selected = [inputs[0], inputs[1], invalidDirectory, inputs[0], inputs[2]]
        let result = try await ImageBatchRunner().run(inputs: selected, audit: { input in
            await probe.begin(input.lastPathComponent)
            await Task.yield()
            await probe.end()
            if input == inputs[1] { throw ReportError.invalidContents("Owned unsupported-image diagnostic") }
            return raw
        }, retain: { data, input in
            try await library.keep(data, provenance: LibraryProvenance(sourceLabel: input.path, inspectedInput: input))
        })
        XCTAssertEqual(result.items.map(\.status), [.completed, .failed, .failed, .duplicate, .completed])
        XCTAssertEqual(result.items.map(\.input), selected)
        XCTAssertEqual(Set(result.items.map(\.id)).count, selected.count)
        XCTAssertTrue(result.settled)
        let state = await probe.state()
        XCTAssertEqual(state.0, inputs.map(\.lastPathComponent))
        XCTAssertEqual(state.2, 1)
        for item in result.items where item.status == .completed {
            let kept = try await library.load(XCTUnwrap(item.retainedReportID))
            XCTAssertEqual(kept.data, raw)
            XCTAssertEqual(kept.provenance.inspectedInput, item.input)
            XCTAssertEqual(item.image?.sliceSHA256, kept.report.image.sliceSHA256)
        }
    }

    func testCancellationSettlesActiveWorkAndPreservesEarlierCompletion() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ImageBatchRunner(); let probe = BatchProbe()
        let library = ReportLibrary(root: root.appendingPathComponent("library"))
        let task = Task {
            try await runner.run(inputs: inputs, audit: { input in
                await probe.begin(input.lastPathComponent)
                if input == inputs[1] {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { await probe.end(); throw error }
                }
                await probe.end()
                return raw
            }, retain: { data, input in
                try await library.keep(data, provenance: LibraryProvenance(sourceLabel: input.path))
            })
        }
        try await waitFor { await probe.state().0.count == 2 }
        do {
            _ = try await runner.run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in UUID() })
            XCTFail("Concurrent batch admitted")
        } catch EngineError.busy {}
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.items.map(\.status), [.completed, .cancelled, .notStarted])
        let state = await probe.state()
        XCTAssertEqual(state.1, 0)
        let saved = try await library.load(XCTUnwrap(result.items[0].retainedReportID))
        XCTAssertEqual(saved.data, raw)
    }

    func testCancellationDuringCommitPreservesThatCompletedResult() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = BatchGate(); let id = UUID()
        let task = Task {
            try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in
                await gate.wait()
                return id
            })
        }
        try await waitFor { await gate.entered }
        task.cancel()
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.items.map(\.status), [.completed, .notStarted, .notStarted])
        XCTAssertEqual(result.items[0].retainedReportID, id)
    }

    func testRetentionFailurePreservesCompletedBytesAndStopsBeforeAnotherImage() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = BatchProbe()
        let result = try await ImageBatchRunner().run(inputs: inputs, audit: { _ in raw }, retain: { _, _ in
            if await probe.nextRetention() == 2 { throw ReportError.invalidContents("Owned storage full") }
            return UUID()
        })
        XCTAssertEqual(result.items.map(\.status), [.completed, .completed, .notStarted])
        XCTAssertNotNil(result.items[0].retainedReportID)
        XCTAssertEqual(result.items[1].unretainedData, raw)
        XCTAssertNil(result.items[1].retainedReportID)
        XCTAssertTrue(result.hasUnretainedReports)
    }

    func testByteBudgetStopsBeforeLaunchingUnreservedImage() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = BatchProbe()
        let result = try await ImageBatchRunner(maximumReportBytes: raw.count, maximumTotalBytes: raw.count)
            .run(inputs: inputs, audit: { input in await probe.begin(input.lastPathComponent); return raw }, retain: { _, _ in UUID() })
        XCTAssertEqual(result.items.map(\.status), [.completed, .notStarted, .notStarted])
        let state = await probe.state()
        XCTAssertEqual(state.0.count, 1)
    }

    func testInvalidAndOversizedOutputsRemainFailedWithoutRetention() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = BatchProbe()
        let result = try await ImageBatchRunner(maximumReportBytes: raw.count)
            .run(inputs: Array(inputs.prefix(2)), audit: { input in
                input == inputs[0] ? Data("{}".utf8) : raw + Data(" ".utf8)
            }, retain: { _, _ in _ = await probe.nextRetention(); return UUID() })
        XCTAssertEqual(result.items.map(\.status), [.failed, .failed])
        XCTAssertTrue(result.items.allSatisfy { $0.retainedReportID == nil && $0.unretainedData == nil })
        let retained = await probe.retentionCount()
        XCTAssertEqual(retained, 0)
    }

    func testSelectionLimitRejectsBeforeAnyAudit() async throws {
        let (root, inputs, raw) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let probe = BatchProbe()
        for selection in [[], Array(repeating: inputs[0], count: 17)] {
            do {
                _ = try await ImageBatchRunner().run(inputs: selection, audit: { input in
                    await probe.begin(input.path); return raw
                }, retain: { _, _ in UUID() })
                XCTFail("Invalid selection admitted")
            } catch {}
        }
        let state = await probe.state()
        XCTAssertTrue(state.0.isEmpty)
    }
}
