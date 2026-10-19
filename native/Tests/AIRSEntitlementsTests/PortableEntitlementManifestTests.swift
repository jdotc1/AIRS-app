import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

private actor PortableManifestReader: SnapshotReading {
    private(set) var paths: [String] = []
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        paths.append(url.path)
        let pair = ExampleSnapshots.pair(architecture: architecture)
        return url.lastPathComponent.hasPrefix("Previous") ? pair.previous : pair.current
    }
}

final class PortableEntitlementManifestTests: XCTestCase {
    private func location() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/portable-manifest-evidence/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func pair(in root: URL) -> EntitlementBatchPair {
        .init(previous: root.appendingPathComponent("Previous e\u{301} %20.app", isDirectory: true),
              current: root.appendingPathComponent("nested/Current.app", isDirectory: true), architecture: .x86_64)
    }
    private func raw(path: String, version: Int = 2) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": EntitlementBatchManifest.kind, "version": version,
            "pairs": [["previousPath": path, "currentPath": "Current.app", "architecture": "arm64"]]], options: [.sortedKeys])
    }
    private func createApp(_ url: URL) throws {
        let directory = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Owned placeholder, never executed".utf8).write(to: directory.appendingPathComponent("fixture"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    func testRelativeRoundTripPreservesExactPathsOrderAndVersionOneDefault() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = pair(in: root)
        let legacy = try EntitlementBatchManifest(pairs: [selected])
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(try EntitlementBatchManifest.parse(legacy.data()).data(), try legacy.data())
        let portable = try EntitlementBatchManifest(pairs: [selected, selected], relativeTo: root)
        XCTAssertEqual(portable.version, 2)
        XCTAssertEqual(Array(portable.pairs[0].previousPath.utf8), Array("Previous e\u{301} %20.app".utf8))
        let bytes = try portable.data()
        XCTAssertThrowsError(try EntitlementBatchManifest.parse(bytes))
        let parsed = try EntitlementBatchManifest.parse(bytes, relativeTo: root)
        XCTAssertEqual(try parsed.data(), bytes)
        let restored = parsed.makePairs()
        XCTAssertEqual(restored.map(\.architecture), [.x86_64, .x86_64])
        XCTAssertEqual(Array(restored[0].previous.path.utf8), Array(selected.previous.path.utf8))
        XCTAssertEqual(Set(restored.map(\.id)).count, 2)
        XCTAssertTrue(Set(restored.map(\.id)).isDisjoint(with: parsed.makePairs().map(\.id)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.previous.path))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "version", "pairs"])
    }

    func testRelativeSchemaPathsAndResolvedLengthRejectWithoutFallback() throws {
        let base = URL(fileURLWithPath: "/Unavailable/Base", isDirectory: true)
        for path in ["/Before.app", "../Before.app", "a/../Before.app", "./Before.app", "a//Before.app",
                     "a/./Before.app", "Before.app/", "", "~user/Before.app", "file:///Before.app", "https://host/Before.app",
                     "Before\0.app", "Before.bin"] {
            XCTAssertThrowsError(try EntitlementBatchManifest.parse(raw(path: path), relativeTo: base), path)
        }
        for version in [0, 3, 20] {
            XCTAssertThrowsError(try EntitlementBatchManifest.parse(raw(path: "Before.app", version: version), relativeTo: base))
        }
        let valid = String(decoding: try raw(path: "Before.app"), as: UTF8.self)
        for invalid in [valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":2.0"),
                        valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"ver\\u0073ion\":2"),
                        valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"base\":\"/elsewhere\""),
                        valid + " trailing"] {
            XCTAssertThrowsError(try EntitlementBatchManifest.parse(Data(invalid.utf8), relativeTo: base))
        }
        XCTAssertThrowsError(try EntitlementBatchManifest.parse(raw(path: "Before.app"), relativeTo: URL(string: "https://invalid.example/root")!))
        XCTAssertThrowsError(try EntitlementBatchManifest.parse(raw(path: String(repeating: "x", count: 4090) + ".app"), relativeTo: base))
        let literal = try EntitlementBatchManifest.parse(raw(path: "%2e%2e/Before.app"), relativeTo: base)
        XCTAssertEqual(literal.makePairs()[0].previous.path, "/Unavailable/Base/%2e%2e/Before.app")
        // A shared string prefix is not containment in the selected folder.
        let selected = EntitlementBatchPair(previous: URL(fileURLWithPath: "/root-other/Before.app", isDirectory: true),
            current: URL(fileURLWithPath: "/root-other/Current.app", isDirectory: true), architecture: .arm64)
        XCTAssertThrowsError(try EntitlementBatchManifest(pairs: [selected], relativeTo: URL(fileURLWithPath: "/root", isDirectory: true)))
    }

    func testRelativeExportsProtectInputsSourceAndBaseAndNeverFallBackToAbsolute() throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = pair(in: root)
        try createApp(selected.previous); try createApp(selected.current)
        let manifest = try EntitlementBatchManifest(pairs: [selected], relativeTo: root)
        let destination = root.appendingPathComponent("plan.json")
        try manifest.write(to: destination, excluding: [])
        let bytes = try Data(contentsOf: destination)
        XCTAssertThrowsError(try manifest.write(to: destination, excluding: [destination]))
        XCTAssertThrowsError(try manifest.write(to: selected.previous.appendingPathComponent("plan.json"), excluding: []))
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        XCTAssertThrowsError(try manifest.write(to: alias, excluding: [destination]))
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        XCTAssertThrowsError(try manifest.write(to: elsewhere.appendingPathComponent("plan.json"), excluding: []))
        XCTAssertThrowsError(try EntitlementBatchManifest(pairs: [selected], relativeTo: elsewhere))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try EntitlementBatchManifest.read(destination).data(), bytes)
    }

    func testRelocatedPlanFeedsExistingCommandResolvedPathsAndExplicitArchitecture() async throws {
        let root = try location(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: true)
        let selected = pair(in: original)
        try createApp(selected.previous); try createApp(selected.current)
        try EntitlementBatchManifest(pairs: [selected], relativeTo: original)
            .write(to: original.appendingPathComponent("plan.json"), excluding: [])
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let command = try EntitlementBatchCommand(arguments: ["--manifest", moved.appendingPathComponent("plan.json").path,
            "--output-directory", root.appendingPathComponent("output").path], directory: root)
        let reader = PortableManifestReader()
        let result = try await command.run(reader: reader)
        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertEqual(result.summary.rows.map(\.architecture), [.x86_64])
        let paths = await reader.paths
        XCTAssertEqual(paths, [moved.appendingPathComponent("Previous e\u{301} %20.app").path,
                               moved.appendingPathComponent("nested/Current.app").path])
        let report = try SavedReport.read(at: command.outputDirectory.appendingPathComponent(XCTUnwrap(result.summary.rows[0].reportFile)))
        XCTAssertEqual(report.previous.architecture, .x86_64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }
}
