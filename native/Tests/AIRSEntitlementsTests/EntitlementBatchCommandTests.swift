import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

private actor CommandReader: SnapshotReading {
    private(set) var calls = 0
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        calls += 1
        if url.lastPathComponent.hasPrefix("Broken") { throw CocoaError(.fileReadCorruptFile) }
        if url.lastPathComponent.hasPrefix("Absent") || url.lastPathComponent.hasPrefix("Empty") {
            return .init(sourceName: url.lastPathComponent, signingIdentifier: "owned.fixture",
                architecture: architecture, presence: url.lastPathComponent.hasPrefix("Absent") ? .notPresent : .dictionaryPresent,
                entitlements: .init())
        }
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

final class EntitlementBatchCommandTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/entitlement-batch-cli-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
        let executableDirectory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try Data("Owned fixture bytes, never executed".utf8).write(to: executableDirectory.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }
    private func command(_ pairs: [EntitlementBatchPair], root: URL, name: String = "run") throws -> EntitlementBatchCommand {
        let manifest = root.appendingPathComponent(name + ".json")
        try EntitlementBatchManifest(pairs: pairs).data().write(to: manifest)
        return try EntitlementBatchCommand(arguments: ["--manifest", manifest.lastPathComponent,
            "--output-directory", name + " output"], directory: root)
    }

    func testStrictArgumentsAndInvalidOrProtectedDestinationsFailBeforeReads() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let args = ["--manifest", "plan.json", "--output-directory", "output"]
        for invalid in [[], Array(args.dropLast()), args + ["--manifest", "other.json"],
                        args + ["--architecture", "arm64"], ["--manifest", "", "--output-directory", "out"]] {
            XCTAssertThrowsError(try EntitlementBatchCommand(arguments: invalid, directory: root))
        }
        let input = try app("Previous", in: root), reader = CommandReader()
        let command = try command([.init(previous: input, current: input, architecture: .arm64)], root: root)
        let alias = root.appendingPathComponent("input-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("keep")
        try Data("unchanged".utf8).write(to: marker)
        let directoryAlias = root.appendingPathComponent("existing-alias")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: existing)
        for destination in [existing, directoryAlias, input.appendingPathComponent("output"),
                            alias.appendingPathComponent("output"), command.manifestURL] {
            let blocked = try EntitlementBatchCommand(arguments: ["--manifest", command.manifestURL.path,
                "--output-directory", destination.path])
            do { _ = try await blocked.run(reader: reader); XCTFail("Protected destination accepted") } catch {}
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "unchanged")
        try Data("{}".utf8).write(to: command.manifestURL)
        do { _ = try await command.run(reader: reader); XCTFail("Invalid manifest admitted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.outputDirectory.path))
        let calls = await reader.calls; XCTAssertEqual(calls, 0)
    }

    func testOrderedReportsDuplicatesAndFailuresHaveErrorPrecedence() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = try app("Previous", in: root), current = try app("Current", in: root)
        let broken = try app("Broken", in: root)
        let pair = EntitlementBatchPair(previous: previous, current: current, architecture: .arm64)
        let command = try command([pair, pair,
            .init(previous: broken, current: current, architecture: .x86_64),
            .init(previous: previous, current: previous, architecture: .x86_64)], root: root)
        let reader = CommandReader(), result = try await command.run(reader: reader)
        XCTAssertEqual(result.exitStatus, 2)
        XCTAssertEqual(result.summary.rows.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(result.summary.rows.map(\.status), [.completed, .duplicate, .failed, .completed])
        XCTAssertEqual(result.summary.rows.map(\.differences), [true, nil, nil, false])
        XCTAssertNil(result.summary.rows[2].changedCount)
        XCTAssertNil(result.summary.rows[1].reportFile)
        for row in result.summary.rows where row.status == .completed {
            let filename = try XCTUnwrap(row.reportFile)
            let saved = try SavedReport.read(at: command.outputDirectory.appendingPathComponent(filename))
            XCTAssertEqual(saved.previous.architecture, row.architecture)
        }
        XCTAssertEqual(try Data(contentsOf: command.outputDirectory.appendingPathComponent("summary.json")), result.standardOutput)
        let calls = await reader.calls; XCTAssertEqual(calls, 5)
    }

    func testPresenceOnlyDifferenceAndEqualityExitStatuses() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let absent = try app("Absent", in: root), empty = try app("Empty", in: root)
        let different = try command([.init(previous: absent, current: empty, architecture: .arm64)], root: root, name: "representation")
        let result = try await different.run(reader: CommandReader())
        XCTAssertEqual(result.exitStatus, 1); XCTAssertEqual(result.summary.rows[0].changedCount, 0)
        XCTAssertEqual(result.summary.rows[0].differences, true)
        let equal = try command([.init(previous: empty, current: empty, architecture: .arm64)], root: root, name: "equal")
        let equality = try await equal.run(reader: CommandReader())
        XCTAssertEqual(equality.exitStatus, 0); XCTAssertEqual(equality.summary.rows[0].differences, false)
    }

    func testReportWriteFailureStopsLaterReadsAndCannotClaimSavedSuccess() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = try app("Previous", in: root), current = try app("Current", in: root)
        let command = try command([.init(previous: previous, current: current, architecture: .arm64),
            .init(previous: current, current: previous, architecture: .arm64)], root: root)
        let reader = CommandReader()
        let result = try await command.execute(reader: reader, writeReport: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(result.exitStatus, 2)
        XCTAssertEqual(result.summary.rows.map(\.status), [.completed, .notStarted])
        XCTAssertNil(result.summary.rows[0].reportFile); XCTAssertNil(result.summary.rows[0].differences)
        XCTAssertTrue(result.summary.rows[0].message.contains("not retained"))
        let calls = await reader.calls; XCTAssertEqual(calls, 2)
    }

    func testSummaryPublicationFailurePreservesCompleteReportAndExistingFile() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let input = try app("Previous", in: root)
        let command = try command([.init(previous: input, current: input, architecture: .arm64)], root: root)
        do {
            _ = try await command.execute(reader: CommandReader(), writeReport: { data, url in
                try data.write(to: url, options: .withoutOverwriting)
                try Data("existing summary".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("summary.json"))
            })
            XCTFail("Existing summary overwritten")
        } catch {}
        let files = try FileManager.default.contentsOfDirectory(at: command.outputDirectory, includingPropertiesForKeys: nil)
        let report = try XCTUnwrap(files.first { $0.lastPathComponent != "summary.json" })
        _ = try SavedReport.read(at: report)
        XCTAssertEqual(try String(contentsOf: command.outputDirectory.appendingPathComponent("summary.json"), encoding: .utf8), "existing summary")
    }
}
