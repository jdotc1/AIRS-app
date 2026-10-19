import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

final class EntitlementBatchManifestTests: XCTestCase {
    private func pair(previous: String = "/Unavailable/Before.app", current: String = "/Unavailable/After.app", architecture: Architecture = .arm64) -> EntitlementBatchPair {
        .init(previous: URL(fileURLWithPath: previous, isDirectory: true), current: URL(fileURLWithPath: current, isDirectory: true), architecture: architecture)
    }
    private func raw(_ pairs: String, fields: String = "") -> Data {
        Data("{\"kind\":\"airs-entitlement-batch-manifest\",\"version\":1,\"pairs\":\(pairs)\(fields)}".utf8)
    }
    private let entry = "{\"previousPath\":\"/Absent/Before.app\",\"currentPath\":\"/Absent/After.app\",\"architecture\":\"arm64\"}"

    func testRoundTripPreservesOrderedPathsArchitecturesAndDuplicatesButCreatesFreshIDs() throws {
        let before = "/Unavailable/Unicode e\u{301} space \"quoted\" $literal.app"
        let inputs = [pair(previous: before, architecture: .x86_64), pair(), pair()]
        let data = try EntitlementBatchManifest(pairs: inputs).data()
        let parsed = try EntitlementBatchManifest.parse(data)
        let restored = parsed.makePairs()
        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(Array(restored[0].previous.path.utf8), Array(before.utf8))
        XCTAssertEqual(restored.map(\.architecture), [.x86_64, .arm64, .arm64])
        XCTAssertEqual(restored[1].previous, restored[2].previous)
        XCTAssertEqual(Set(restored.map(\.id)).count, 3)
        XCTAssertTrue(Set(restored.map(\.id)).isDisjoint(with: inputs.map(\.id)))
        XCTAssertTrue(Set(parsed.makePairs().map(\.id)).isDisjoint(with: restored.map(\.id)))
        XCTAssertEqual(try parsed.data(), data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "version", "pairs"])
        let selections = try XCTUnwrap(object["pairs"] as? [[String: Any]])
        XCTAssertEqual(Set(selections[0].keys), ["previousPath", "currentPath", "architecture"])
    }

    func testRejectsAmbiguousSchemaClaimsNestedContentAndUnsupportedSelections() throws {
        let valid = String(decoding: raw("[\(entry)]"), as: UTF8.self)
        let rejected = [
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"ver\\u0073ion\":1"),
            valid.replacingOccurrences(of: "airs-entitlement-batch-manifest", with: "airs-entitlement-batch-history"),
            valid.replacingOccurrences(of: "\"arm64\"", with: "\"arm64e\""),
            valid.replacingOccurrences(of: "\"arm64\"", with: "[\"arm64\"]"),
            valid.replacingOccurrences(of: "\"architecture\":\"arm64\"", with: "\"architecture\":\"arm64\",\"architecture\":\"x86_64\""),
            valid.replacingOccurrences(of: "\"architecture\":\"arm64\"", with: "\"architecture\":\"arm64\",\"status\":\"completed\""),
            valid + " trailing", valid + valid,
            String(decoding: raw("[\(entry)]", fields: ",\"executionID\":\"authority\""), as: UTF8.self),
            String(decoding: raw("[]"), as: UTF8.self),
            String(decoding: raw("[\(entry),]"), as: UTF8.self),
            "{\"kind\":\"airs-entitlement-batch-manifest\",\"version\":1,\"pairs\":\(String(repeating: "[", count: 20))}"
        ]
        for input in rejected { XCTAssertThrowsError(try EntitlementBatchManifest.parse(Data(input.utf8)), input) }
        for path in ["Relative.app", "~/App.app", "file:///App.app", "https://host/App.app", "//host/App.app", "/a/../App.app", "/a/./App.app", "/a//App.app", "/App.app/", "/App.bin", "/NUL\0.app"] {
            let object: [String: Any] = ["kind": EntitlementBatchManifest.kind, "version": 1,
                "pairs": [["previousPath": path, "currentPath": "/After.app", "architecture": "arm64"]]]
            XCTAssertThrowsError(try EntitlementBatchManifest.parse(JSONSerialization.data(withJSONObject: object)), path)
        }
    }

    func testBudgetsAndRegularFileBoundaryAreEnforcedWithoutPartialPlans() throws {
        XCTAssertThrowsError(try EntitlementBatchManifest(pairs: []))
        XCTAssertThrowsError(try EntitlementBatchManifest.parse(raw("[" + Array(repeating: entry, count: 17).joined(separator: ",") + "]")))
        XCTAssertEqual(try EntitlementBatchManifest.parse(raw("[" + Array(repeating: entry, count: 16).joined(separator: ",") + "]")).pairs.count, 16)
        XCTAssertThrowsError(try EntitlementBatchManifest.parse(Data(repeating: 32, count: EntitlementBatchManifest.maximumBytes + 1)))
        XCTAssertThrowsError(try EntitlementBatchManifest(pairs: [pair(previous: "/" + String(repeating: "x", count: 4096) + ".app")]))
        XCTAssertThrowsError(try EntitlementBatchManifest.read(URL(string: "https://example.invalid/manifest.json")!))
        XCTAssertThrowsError(try EntitlementBatchManifest.read(URL(fileURLWithPath: #filePath).deletingLastPathComponent()))
    }

    func testExportProtectsSelectedAppsAliasesAndCallerSourcesAndRoundTripsFromDisk() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/entitlement-manifest-evidence/core/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Owned.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let marker = app.appendingPathComponent("unchanged.json")
        let original = Data("Original input data".utf8); try original.write(to: marker)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let manifest = try EntitlementBatchManifest(pairs: [.init(previous: app, current: app, architecture: .arm64)])
        XCTAssertThrowsError(try manifest.write(to: marker, excluding: []))
        XCTAssertThrowsError(try manifest.write(to: alias.appendingPathComponent("new.json"), excluding: []))
        let source = root.appendingPathComponent("source.json"); try original.write(to: source)
        XCTAssertThrowsError(try manifest.write(to: source, excluding: [source]))
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertEqual(try Data(contentsOf: marker), original)
        let output = root.appendingPathComponent("export.json")
        try manifest.write(to: output, excluding: [source])
        XCTAssertEqual(try EntitlementBatchManifest.read(output).data(), try manifest.data())
    }
}
