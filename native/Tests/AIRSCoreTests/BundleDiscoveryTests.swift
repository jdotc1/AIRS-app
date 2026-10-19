import Darwin
import Foundation
import XCTest
@testable import AIRSCore

private actor DiscoveryAuditCalls {
    var inputs: [URL] = []
    func add(_ url: URL) { inputs.append(url) }
    func values() -> [URL] { inputs }
}
final class BundleDiscoveryTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture() throws -> (URL, URL) {
        let root = project.appendingPathComponent("build/bundle-discovery-evidence/tests/\(UUID())"), app = root.appendingPathComponent("Owned.app")
        for folder in ["Contents/MacOS", "Contents/Frameworks/Owned.framework/Versions/A", "Contents/Helpers", "Contents/Resources", "Contents/XPCServices/Owned.xpc/Contents/MacOS"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "OwnedMain"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let image = try Data(contentsOf: project.appendingPathComponent("fixtures/generated/before.macho"))
        for file in ["Contents/MacOS/OwnedMain", "Contents/Frameworks/Owned.framework/Versions/A/Owned", "Contents/Helpers/helper", "Contents/XPCServices/Owned.xpc/Contents/MacOS/service"] {
            try image.write(to: app.appendingPathComponent(file))
        }
        try Data("Resource, not image".utf8).write(to: app.appendingPathComponent("Contents/Helpers/readme.txt"))
        try image.write(to: app.appendingPathComponent("Contents/Resources/outside-code-scope"))
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/Frameworks/Owned.framework/Versions/Current").path, withDestinationPath: "A")
        return (root, app)
    }
    func testOwnedBundleCandidatesScopesAndLinksNeverAnalyzeOrExecute() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try BundleDiscovery().discover(app)
        XCTAssertFalse(result.partial); XCTAssertEqual(result.entries.filter(\.selectable).count, 4)
        XCTAssertTrue(result.entries.contains { $0.state == "skipped_link" })
        XCTAssertTrue(result.entries.contains { $0.state == "non_image" })
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("Resources") })
        let main = try XCTUnwrap(result.entries.first { $0.relativePath == "Contents/MacOS/OwnedMain" }?.provenance)
        XCTAssertEqual(main.bundle, app); XCTAssertTrue(result.entries.first { $0.provenance == main }?.message.contains("Principal executable") == true)
        XCTAssertNoThrow(try BundleDiscovery.validate(main, input: app.appendingPathComponent(main.relativePath)))
        XCTAssertLessThanOrEqual(result.headerBytes, 1_048_576)
    }
    func testHardlinksDeduplicateAndDirectoryLinksCannotEscape() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: app.appendingPathComponent("Contents/Helpers/helper"), to: app.appendingPathComponent("Contents/Helpers/same-file"))
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Contents/MacOS/OwnedMain"), to: outside.appendingPathComponent("outside-image"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/Helpers/escape"), withDestinationURL: outside)
        let result = try BundleDiscovery().discover(app)
        XCTAssertEqual(result.entries.filter(\.selectable).count, 4)
        XCTAssertEqual(result.entries.filter { $0.state == "duplicate_file" }.count, 1)
        XCTAssertFalse(result.entries.contains { $0.relativePath.contains("outside-image") })
        XCTAssertTrue(result.entries.contains { $0.relativePath.hasSuffix("escape") && $0.state == "skipped_link" })
    }
    func testEntryDepthCandidateAndHeaderLimitsAreVisible() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let entry = try BundleDiscovery(limits: .init(entries: 1)).discover(app)
        XCTAssertTrue(entry.partial); XCTAssertTrue(entry.entries.contains { $0.state == "entry_limit" })
        let depth = try BundleDiscovery(limits: .init(depth: 1)).discover(app)
        XCTAssertTrue(depth.partial); XCTAssertTrue(depth.entries.contains { $0.state == "depth_limit" })
        let candidates = try BundleDiscovery(limits: .init(candidates: 1)).discover(app)
        XCTAssertTrue(candidates.partial); XCTAssertEqual(candidates.entries.filter(\.selectable).count, 1)
        XCTAssertTrue(candidates.entries.contains { $0.state == "candidate_limit" })
        let header = try BundleDiscovery(limits: .init(headerBytes: 4096)).discover(app)
        XCTAssertTrue(header.partial); XCTAssertTrue(header.entries.contains { $0.state == "header_limit" })
        XCTAssertLessThanOrEqual(header.headerBytes, 4096)
    }
    func testChangedInputRootAndIntermediateLinksRejectBeforeOwnedAudit() async throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let discovery = try BundleDiscovery().discover(app)
        let row = try XCTUnwrap(discovery.entries.first { $0.relativePath == "Contents/Helpers/helper" }), provenance = try XCTUnwrap(row.provenance)
        let input = app.appendingPathComponent(row.relativePath)
        try Data("Changed".utf8).write(to: input)
        let calls = DiscoveryAuditCalls(), raw = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json"))
        let result = try await ImageBatchRunner().run(inputs: [input], bundleImages: [input: provenance], audit: { url in await calls.add(url); return raw }, retain: { _, _ in UUID() })
        XCTAssertEqual(result.items[0].status, .failed); let values = await calls.values(); XCTAssertTrue(values.isEmpty)
        let helper = app.appendingPathComponent("Contents/Helpers"), moved = app.appendingPathComponent("Contents/OriginalHelpers")
        try FileManager.default.moveItem(at: helper, to: moved); try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: moved)
        XCTAssertThrowsError(try BundleDiscovery.validate(provenance, input: input))
        try FileManager.default.moveItem(at: app, to: root.appendingPathComponent("Moved.app"))
        XCTAssertThrowsError(try BundleDiscovery.validate(provenance, input: input))
    }
    func testProvenanceSurvivesLibraryCheckpointAndResumeWithoutRewritingRawReport() async throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let candidates = try BundleDiscovery().discover(app).entries.filter(\.selectable)
        let chosen = Array(candidates.prefix(2)), inputs = chosen.compactMap { $0.provenance.map { $0.bundle.appendingPathComponent($0.relativePath) } }
        let provenance = try Dictionary(uniqueKeysWithValues: zip(inputs, chosen).map { ($0.0, try XCTUnwrap($0.1.provenance)) })
        let raw = try Data(contentsOf: project.appendingPathComponent("examples/before.audit.json")), history = BatchHistory(root: root.appendingPathComponent("history")), library = ReportLibrary(root: root.appendingPathComponent("library"))
        let initial = try await ImageBatchRunner().run(inputs: inputs, bundleImages: provenance, audit: { url in if url == inputs[1] { throw CancellationError() }; return raw }, retain: { data, input in
            try await library.keep(data, provenance: LibraryProvenance(sourceLabel: input.path, inspectedInput: input, bundleImage: provenance[input]))
        }, checkpoint: { try await history.save($0) })
        XCTAssertEqual(initial.items.map(\.status), [.completed, .cancelled])
        let restored = try await history.load(initial.id)
        XCTAssertEqual(restored.items.map(\.bundleImage), initial.items.map(\.bundleImage))
        let resumed = try await ImageBatchRunner().run(inputs: inputs, resuming: restored, audit: { _ in raw }, retain: { _, _ in UUID() })
        XCTAssertEqual(resumed.items.map(\.status), [.completed, .completed]); XCTAssertEqual(resumed.items[1].bundleImage, provenance[inputs[1]])
        let stored = try await library.load(XCTUnwrap(initial.items[0].retainedReportID)); XCTAssertEqual(stored.data, raw); XCTAssertEqual(stored.provenance.bundleImage, provenance[inputs[0]])
        let oldID = try await library.keep(raw, provenance: LibraryProvenance(sourceLabel: inputs[0].path, inspectedInput: inputs[0]))
        XCTAssertNotEqual(oldID, initial.items[0].retainedReportID, "Legacy provenance must not absorb a bundle receipt")
    }
    func testCancelledDiscoveryAndMalformedOrUnsupportedHeadersRemainExplicit() async throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let job = Task { () throws -> BundleDiscoveryResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try BundleDiscovery().discover(app)
        }
        let cancelled = try await job.value; XCTAssertTrue(cancelled.cancelled); XCTAssertTrue(cancelled.partial)
        var object = [UInt8](repeating: 0, count: 32); object[0..<4] = [0xcf,0xfa,0xed,0xfe]; object[12] = 1
        try Data(object).write(to: app.appendingPathComponent("Contents/Helpers/object.o"))
        try Data([0xca,0xfe,0xba,0xbe,0,0,0,65]).write(to: app.appendingPathComponent("Contents/Helpers/bad-fat"))
        try FileManager.default.copyItem(at: project.appendingPathComponent("fixtures/generated/universal64.macho"), to: app.appendingPathComponent("Contents/Helpers/universal"))
        let result = try BundleDiscovery().discover(app)
        XCTAssertTrue(result.entries.contains { $0.state == "unsupported_type" })
        XCTAssertTrue(result.entries.contains { $0.state == "malformed_header" })
        XCTAssertTrue(result.entries.contains { $0.relativePath.hasSuffix("universal") && $0.selectable && $0.message.contains("Slice validation pending") })
    }
    func testInvalidNamesConsumeEntryBudgetAndRemainVisible() throws {
        let (root, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let normal = try BundleDiscovery().discover(app)
        XCTAssertEqual(normal.entries.filter(\.selectable).count, 4)
        let directory = app.appendingPathComponent("Contents/MacOS")
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { XCTFail("Owned directory unavailable"); return }; defer { Darwin.close(fd) }
        for byte: UInt8 in [0xfe, 0xff] {
            let name: [CChar] = [CChar(bitPattern: byte), 0]
            let file = name.withUnsafeBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.openat(fd, base, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
            }
            if file < 0 {
                let code = errno
                if code == EILSEQ || code == EINVAL {
                    throw XCTSkip("Host filesystem rejects non-UTF8 filenames (errno \(code)); byte-name branch reviewed statically.")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            Darwin.close(file)
        }
        let result = try BundleDiscovery(limits: .init(entries: 2)).discover(app)
        XCTAssertEqual(result.visited, 2); XCTAssertTrue(result.partial)
        XCTAssertTrue(result.entries.contains { $0.state == "entry_limit" })
        XCTAssertTrue(result.entries.contains { $0.state == "invalid_name" })
    }

}
