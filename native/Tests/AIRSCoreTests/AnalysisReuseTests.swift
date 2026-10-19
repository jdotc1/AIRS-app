import Foundation
import XCTest
@testable import AIRSCore

private func reuseUnwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

private struct ReuseFixture {
    let root: URL
    let input: URL
    let configuration: EngineConfiguration
    let library: ReportLibrary
    let cache: AnalysisReuse
    let raw: Data
    init(maximumEntries: Int = 128, libraryMaximum: Int = 128) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = project.appendingPathComponent("build/analysis-reuse-evidence/tests/\(UUID().uuidString)")
        let python = root.appendingPathComponent("AIRS.app/Contents/Frameworks/Python.framework/Versions/3.15/bin/python3.15")
        let bootstrap = root.appendingPathComponent("AIRS.app/Contents/Resources/Engine/airs_cli.py")
        input = root.appendingPathComponent("owned.input")
        for file in [python, bootstrap, input] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Owned placeholder, never executed".utf8).write(to: file)
        }
        configuration = EngineConfiguration(pythonExecutable: python, bootstrap: bootstrap, isBundled: true)
        library = ReportLibrary(root: root.appendingPathComponent("library"), maximumEntries: libraryMaximum)
        cache = AnalysisReuse(root: root.appendingPathComponent("reuse"), library: library, maximumEntries: maximumEntries)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("examples/mixed.audit.json"))) as? [String: Any])
        object["generator"] = ["name":"AIRS", "version":"0.1.0", "analysis_model_version":"arm64-bounded-sequential-loops-v31"]
        object["future_unknown"] = ["kept":true]
        raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n \n".utf8)
    }
    func enroll(data: Data? = nil) async throws -> UUID {
        let ticket = try reuseUnwrap(try await cache.ticket(input: input, configuration: configuration))
        let id = try await cache.enroll(data ?? raw, input: input, configuration: configuration, before: ticket,
            provenance: LibraryProvenance(sourceLabel: "Owned replay", inspectedInput: input))
        return try XCTUnwrap(id)
    }
    func lookup() async throws -> AnalysisReuseHit? {
        let ticket = try reuseUnwrap(try await cache.ticket(input: input, configuration: configuration))
        return try await cache.lookup(ticket, input: input, configuration: configuration)
    }
}

final class AnalysisReuseTests: XCTestCase {
    func testOwnedAdmissionPersistsExactRawReportAndFullSliceIdentity() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.enroll()
        let cache = AnalysisReuse(root: f.root.appendingPathComponent("reuse"), library: f.library)
        let ticket = try reuseUnwrap(try await cache.ticket(input: f.input, configuration: f.configuration))
        let hit = try reuseUnwrap(try await cache.lookup(ticket, input: f.input, configuration: f.configuration))
        XCTAssertEqual(hit.retainedID, id); XCTAssertEqual(hit.data, f.raw)
        let report = try AuditReport.decode(hit.data)
        XCTAssertEqual(report.image.sliceSHA256, try AuditReport.decode(f.raw).image.sliceSHA256)
        XCTAssertEqual(report.summary.unresolvedCount, 4)
    }
    func testImportedReportAloneNeverEnrolls() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.library.keep(f.raw, provenance: LibraryProvenance(sourceLabel: "Import", inspectedInput: f.input))
        let hit = try await f.lookup(); XCTAssertNil(hit)
    }
    func testInputMutationWithSameSizeAndRestoredMtimeRejects() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.enroll()
        let attributes = try FileManager.default.attributesOfItem(atPath: f.input.path)
        let size = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        try Data(repeating: 65, count: size).write(to: f.input)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: f.input.path)
        let hit = try await f.lookup(); XCTAssertNil(hit)
    }
    func testRuntimeAndBootstrapChangesRejectAndExternalOverrideIneligible() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.enroll()
        try Data("Changed private runtime".utf8).write(to: f.configuration.pythonExecutable)
        var hit = try await f.lookup(); XCTAssertNil(hit)
        try Data("Changed bootstrap".utf8).write(to: f.configuration.bootstrap)
        hit = try await f.lookup(); XCTAssertNil(hit)
        let external = EngineConfiguration(pythonExecutable: f.configuration.pythonExecutable, bootstrap: f.configuration.bootstrap)
        let ticket = try await f.cache.ticket(input: f.input, configuration: external); XCTAssertNil(ticket)
    }
    func testSymlinkRetargetAndEscapingEngineOverrideDecline() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let directory = f.configuration.bootstrap.deletingLastPathComponent()
        let a = directory.appendingPathComponent("a.py"), b = directory.appendingPathComponent("b.py"), link = directory.appendingPathComponent("alias.py")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.py")
        _ = try await f.enroll()
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "b.py")
        let hit = try await f.lookup(); XCTAssertNil(hit)
        let outside = EngineConfiguration(pythonExecutable: f.configuration.pythonExecutable, bootstrap: f.input, isBundled: true)
        let ticket = try await f.cache.ticket(input: f.input, configuration: outside); XCTAssertNil(ticket)
    }
    func testChangedDuringGenerationCannotEnrollAndLibraryCorruptionCannotHit() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try reuseUnwrap(try await f.cache.ticket(input: f.input, configuration: f.configuration))
        try Data("Changed while owned audit ran".utf8).write(to: f.input)
        let declined = try await f.cache.enroll(f.raw, input: f.input, configuration: f.configuration, before: before,
            provenance: LibraryProvenance(sourceLabel: "Replay", inspectedInput: f.input))
        XCTAssertNil(declined)
        let id = try await f.enroll()
        try (f.raw + Data(" ".utf8)).write(to: f.root.appendingPathComponent("library/\(id.uuidString)/report.json"))
        let hit = try await f.lookup(); XCTAssertNil(hit)
    }
    func testBoundedBatchHitStartsNoAuditOrRetentionAndPreservesBytes() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.enroll()
        let runner = ImageBatchRunner()
        let snapshot = try await runner.run(inputs: [f.input], audit: { _ in
            XCTFail("Reuse started analysis"); throw EngineError.busy
        }, reuse: { _ in try await f.lookup() }, retain: { _, _ in
            XCTFail("Reuse rewrote retained report"); throw EngineError.busy
        })
        XCTAssertEqual(snapshot.items.first?.status, .completed)
        XCTAssertEqual(snapshot.items.first?.retainedReportID, id)
        XCTAssertNotNil(snapshot.items.first?.reusedAt)
        XCTAssertTrue(snapshot.items.first?.message.contains("Reused saved analysis") == true)
        let saved = try await f.library.load(id); XCTAssertEqual(saved.data, f.raw)
    }
    func testEntryLimitDoesNotDiscardGeneratedData() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cache = AnalysisReuse(root: f.root.appendingPathComponent("limited"), library: f.library, maximumEntries: 0)
        let ticket = try reuseUnwrap(try await cache.ticket(input: f.input, configuration: f.configuration))
        let id = try await cache.enroll(f.raw, input: f.input, configuration: f.configuration, before: ticket,
            provenance: LibraryProvenance(sourceLabel: "Replay", inspectedInput: f.input))
        XCTAssertNil(id); XCTAssertNoThrow(try AuditReport.decode(f.raw))
    }
    func testCancellationKeepsCompletedReuseAndAccountsForRemainingInput() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.enroll()
        let second = f.root.appendingPathComponent("pending.input")
        try Data("owned pending".utf8).write(to: second)
        let work = Task {
            try await ImageBatchRunner().run(inputs: [f.input, second], audit: { _ in
                XCTFail("Unexpected analysis after reuse/cancellation"); throw EngineError.busy
            }, reuse: { _ in try await f.lookup() }, retain: { _, _ in throw EngineError.busy }, progress: { snapshot in
                if snapshot.items.first?.status == .completed { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        let result = try await work.value
        XCTAssertEqual(result.items[0].status, .completed)
        XCTAssertEqual(result.items[0].retainedReportID, id)
        XCTAssertEqual(result.items[1].status, .notStarted)
        let raw = try await f.library.load(id); XCTAssertEqual(raw.data, f.raw)
    }
    func testReceiptWrongSliceOrConfigurationNeverHits() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.enroll()
        let files = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("reuse"), includingPropertiesForKeys: nil)
        let receipt = try XCTUnwrap(files.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        var image = try XCTUnwrap(object["image"] as? [String: Any])
        image["slice_offset"] = 4096; object["image"] = image
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        let wrongSlice = try await f.lookup(); XCTAssertNil(wrongSlice)
        image["slice_offset"] = 0; object["image"] = image
        object["analysisConfig"] = Data("{}".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        let wrongConfig = try await f.lookup(); XCTAssertNil(wrongConfig)
    }

}

final class AnalysisReuseMaintenanceTests: XCTestCase {
    private func receipts(_ f: ReuseFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("reuse"),
            includingPropertiesForKeys: nil).filter {
                $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))?.isRegularFile == true
                    && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            }
    }

    func testRepeatedAdmissionReplacesReceiptAndKeepsExactRetainedReport() async throws {
        let f = try ReuseFixture(maximumEntries: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.enroll()
        let second = try await f.enroll()
        XCTAssertEqual(first, second)
        XCTAssertEqual(try receipts(f).count, 1)
        let hit = try await f.lookup()
        XCTAssertEqual(hit?.data, f.raw); XCTAssertEqual(hit?.retainedID, first)
        let ids = try await f.library.storedIDs(); XCTAssertEqual(ids, [first])
    }

    func testOldestReceiptEvictionPreservesReportsAndIgnoresUnownedFiles() async throws {
        let f = try ReuseFixture(maximumEntries: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.enroll()
        let firstReceipt = try XCTUnwrap(try receipts(f).first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: firstReceipt)) as? [String: Any])
        object["generatedAt"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: firstReceipt)
        let ignored = f.root.appendingPathComponent("reuse/notes.txt")
        try Data("Preserve this file".utf8).write(to: ignored)
        try Data("Second input generation".utf8).write(to: f.input)
        let second = try await f.enroll(data: f.raw + Data(" ".utf8))
        let middleHit = try await f.lookup(); XCTAssertEqual(middleHit?.retainedID, second)
        try Data("Third input generation".utf8).write(to: f.input)
        let third = try await f.enroll(data: f.raw + Data("  ".utf8))
        XCTAssertEqual(try receipts(f).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstReceipt.path))
        let ids = try await f.library.storedIDs(); XCTAssertEqual(ids, [first, second, third])
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("library/\(first.uuidString)/report.json")), f.raw)
        XCTAssertEqual(try String(contentsOf: ignored), "Preserve this file")
        let hit = try await f.lookup(); XCTAssertEqual(hit?.retainedID, third)
    }

    func testAdmissionReclaimsMissingAndMalformedReceiptsWithoutFollowingLinks() async throws {
        let f = try ReuseFixture(maximumEntries: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.enroll()
        let orphan = try XCTUnwrap(try receipts(f).first)
        let preserved = f.root.appendingPathComponent("preserved-library-entry")
        try FileManager.default.moveItem(at: f.root.appendingPathComponent("library/\(id.uuidString)"), to: preserved)
        let root = f.root.appendingPathComponent("reuse")
        let malformed = root.appendingPathComponent(UUID().uuidString + ".json")
        try Data("malformed".utf8).write(to: malformed)
        let target = f.root.appendingPathComponent("outside.json")
        try Data("Never touch".utf8).write(to: target)
        let link = root.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let directory = root.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let new = try await f.enroll()
        XCTAssertNotEqual(id, new); XCTAssertEqual(try receipts(f).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformed.path))
        XCTAssertEqual(try String(contentsOf: target), "Never touch")
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("report.json")), f.raw)
        let hit = try await f.lookup(); XCTAssertEqual(hit?.retainedID, new)
    }

    func testRecoverableOverflowCollapsesDuplicatesAndPreservesFutureFormats() async throws {
        let f = try ReuseFixture(maximumEntries: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try await f.enroll()
        let bytes = try Data(contentsOf: XCTUnwrap(try receipts(f).first))
        let root = f.root.appendingPathComponent("reuse")
        for _ in 0..<3 { try bytes.write(to: root.appendingPathComponent(UUID().uuidString + ".json")) }
        let future = root.appendingPathComponent(UUID().uuidString + ".json")
        let futureBytes = Data(#"{"version":2,"newPayload":"preserved without v1 fields"}"#.utf8)
        try futureBytes.write(to: future)
        let current = try await f.enroll()
        XCTAssertEqual(current, id); XCTAssertEqual(try receipts(f).count, 2)
        XCTAssertEqual(try Data(contentsOf: future), futureBytes)
        let hit = try await f.lookup(); XCTAssertEqual(hit?.retainedID, id)
    }

    func testFullReportLibraryDoesNotEvictExistingReceipt() async throws {
        let f = try ReuseFixture(maximumEntries: 1, libraryMaximum: 1)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.enroll()
        let file = try XCTUnwrap(try receipts(f).first), bytes = try Data(contentsOf: file)
        try Data("Changed owned input".utf8).write(to: f.input)
        do {
            _ = try await f.enroll(data: f.raw + Data(" ".utf8))
            XCTFail("Full report library accepted a distinct report")
        } catch { XCTAssertTrue(error.localizedDescription.contains("full")) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try receipts(f).count, 1)
    }

    func testMembershipNeverDecodesOrValidatesStoredReports() async throws {
        let f = try ReuseFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let root = f.root.appendingPathComponent("metadata-only"), id = UUID()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        try Data("Invalid report intentionally not read".utf8).write(to: root.appendingPathComponent("\(id.uuidString)/report.json"))
        let store = SnapshotLibrary<Data>(root: root, maximumReportBytes: 1024, decode: { _ in
            XCTFail("Membership decoded report evidence"); return Data()
        })
        let ids = try await store.storedIDs(); XCTAssertEqual(ids, [id])
    }

    func testAdmissionAtScanBoundaryPreservesUsableCacheAndIgnoredFiles() async throws {
        let f = try ReuseFixture(maximumEntries: 2); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.enroll()
        let file = try XCTUnwrap(try receipts(f).first), bytes = try Data(contentsOf: file)
        let root = f.root.appendingPathComponent("reuse")
        for i in 0..<511 { try Data().write(to: root.appendingPathComponent("ignored-\(i)")) }
        let other = f.root.appendingPathComponent("other.input")
        try Data("Other owned input".utf8).write(to: other)
        let ticket = try reuseUnwrap(try await f.cache.ticket(input: other, configuration: f.configuration))
        let declined = try await f.cache.enroll(f.raw, input: other, configuration: f.configuration, before: ticket,
            provenance: LibraryProvenance(sourceLabel: "Other", inspectedInput: other))
        XCTAssertNil(declined)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 512)
        let hit = try await f.lookup(); XCTAssertEqual(hit?.retainedID, first)
        // Replacement frees its own slot and remains possible at the scan cap.
        let replaced = try await f.enroll(); XCTAssertEqual(replaced, first)
        XCTAssertEqual(try receipts(f).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 512)
    }

    func testFutureOnlyCapacityAndOversizedDirectoryDeclineWithoutDeletion() async throws {
        let f = try ReuseFixture(maximumEntries: 1); defer { try? FileManager.default.removeItem(at: f.root) }
        let root = f.root.appendingPathComponent("reuse")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = root.appendingPathComponent(UUID().uuidString + ".json")
        let bytes = Data(#"{"version":2}"#.utf8)
        try bytes.write(to: future)
        let ticket = try reuseUnwrap(try await f.cache.ticket(input: f.input, configuration: f.configuration))
        let declined = try await f.cache.enroll(f.raw, input: f.input, configuration: f.configuration, before: ticket,
            provenance: LibraryProvenance(sourceLabel: "Owned"))
        XCTAssertNil(declined)
        let ids = try await f.library.storedIDs(); XCTAssertTrue(ids.isEmpty)
        // Small owned directory-boundary fixture, not a binary/corpus pass.
        for i in 0..<512 { try Data().write(to: root.appendingPathComponent("ignored-\(i)")) }
        do {
            _ = try await f.cache.enroll(f.raw, input: f.input, configuration: f.configuration, before: ticket,
                provenance: LibraryProvenance(sourceLabel: "Owned"))
            XCTFail("Unbounded directory was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("scan limit")) }
        XCTAssertEqual(try Data(contentsOf: future), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 513)
    }
}
