import Foundation
import XCTest
import EntitlementDiffCore
@testable import AIRSEntitlements

final class InspectionLibraryTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIRS-InspectionLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func document() throws -> InspectionDocument {
        try InspectionDocument(snapshot: ExampleSnapshots.pair(architecture: .arm64).current,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), producerVersion: "0.2.0-test")
    }

    func testCompleteDocumentSurvivesNewStoreAndIdenticalKeepDeduplicates() async throws {
        let root = try location()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InspectionLibrary(root: root)
        let captured = try document()
        let bytes = try InspectionDocumentCodec.encode(captured)
        let id = try await library.keep(captured, label: "Before update")
        let duplicate = try await library.keep(bytes, label: "Before update")
        XCTAssertEqual(id, duplicate)
        let reopened = try await InspectionLibrary(root: root).load(id)
        XCTAssertEqual(reopened.data, bytes)
        XCTAssertEqual(reopened.report.snapshot.entitlements, captured.snapshot.entitlements)
        XCTAssertTrue(reopened.report.snapshot.isSavedBaseline)
        XCTAssertEqual(reopened.report.capturedAt, captured.capturedAt)
        XCTAssertNil(reopened.provenance.inspectedInput)
        XCTAssertNil(reopened.provenance.symbolInput)
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.sourceLabel, "Before update")
        XCTAssertEqual(entries.first?.summary?.architecture, "arm64")
    }

    func testFullLibraryRejectsNewCaptureWithoutDeletingExistingBaseline() async throws {
        let root = try location()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InspectionLibrary(root: root, maximumEntries: 1)
        let id = try await library.keep(document(), label: "Keep this")
        do {
            _ = try await library.keep(document(), label: "Another label")
            XCTFail("A full library must not silently evict the baseline")
        } catch {}
        let retained = try await library.load(id)
        XCTAssertEqual(retained.provenance.sourceLabel, "Keep this")
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
    }

    func testChangedStoredBytesRemainVisibleButCannotBeLoaded() async throws {
        let root = try location()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InspectionLibrary(root: root)
        let id = try await library.keep(document(), label: "Baseline")
        let url = root.appendingPathComponent(id.uuidString).appendingPathComponent("report.json")
        var data = try Data(contentsOf: url)
        data.append(32)
        try data.write(to: url)
        let entries = try await library.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries.first?.issue)
        do {
            _ = try await library.load(id)
            XCTFail("Modified retained bytes must not become accepted evidence")
        } catch {}
    }

    func testInvalidLabelsAndDocumentsDoNotCreateEntries() async throws {
        let root = try location()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InspectionLibrary(root: root)
        let captured = try document()
        for label in ["", " \n ", "line\nbreak", String(repeating: "x", count: 257)] {
            do {
                _ = try await library.keep(captured, label: label)
                XCTFail("Invalid baseline label accepted")
            } catch {}
        }
        do {
            _ = try await library.keep(Data("{}".utf8), label: "Invalid document")
            XCTFail("An invalid capture must not be retained")
        } catch {}
        let entries = try await library.entries()
        XCTAssertTrue(entries.isEmpty)
    }
}

extension InspectionLibraryTests {
    func testSummaryPreservesExactCapturedVersionAndBuild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = EntitlementSnapshot(sourceName: "Fixture.app", signingIdentifier: "fixture", architecture: .arm64,
            presence: .dictionaryPresent, origin: .extracted, entitlements: .init(),
            identity: AppIdentity(infoPlist: ["CFBundleShortVersionString":"1/2", "CFBundleVersion":"e\u{301}"]))
        let value = try InspectionDocument(snapshot: snapshot, capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")
        let library = InspectionLibrary(root: root)
        _ = try await library.keep(value, label: "Owned baseline")
        let entries = try await library.entries()
        let summary = try XCTUnwrap(entries.first?.summary)
        XCTAssertEqual(summary.identity?.version, "1/2")
        XCTAssertEqual(Array(try XCTUnwrap(summary.identity?.build).utf8), Array("e\u{301}".utf8))
    }
}

extension InspectionLibraryTests {
    func testBaselineSearchIncludesBuildAndArchitectureIndependently() throws {
        let summary = InspectionLibrarySummary(identity: try InspectionIdentity(bundleIdentifier: "org.example.product", version: "1.2", build: "1234"),
            sourceName: "Fixture.app", signingIdentifier: "signing", architecture: "x86_64", capturedAt: Date(), producerVersion: "0.2.0", entitlementCount: 1)
        for query in ["", "My baseline", "Fixture", "org.example", "1.2", "1234", "x86_64"] {
            XCTAssertTrue(summary.matches(query, label: "My baseline"), query)
        }
        XCTAssertFalse(summary.matches("unrelated", label: "My baseline"))
    }
}
