import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSEntitlements
final class CodeUnitReaderTests: XCTestCase {
    func fixture() throws -> (URL, BundleImageProvenance) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-component-review-20261020/unit-tests/\(UUID())/Owned.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable":"Main", "CFBundleIdentifier":"example.unit", "CFBundleShortVersionString":"1.0", "CFBundlePackageType":"APPL"], format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("fixtures/generated/before.macho"), to: root.appendingPathComponent("Contents/MacOS/Main"))
        return (root, try XCTUnwrap(BundleDiscovery().discover(root).entries.first(where: \.selectable)?.provenance))
    }
    func snapshot(_ architecture: Architecture) -> EntitlementSnapshot {
        .init(sourceName: "ignored", signingIdentifier: "example.unit", architecture: architecture, presence: .dictionaryPresent, entitlements: .init(["key": .boolean(true)]))
    }
    func testPreflightAndExactSliceRead() async throws {
        let (app, unit) = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let value = snapshot(.arm64), reader = CodeUnitEntitlementReader(extract: { _,_ in value })
        let result = try await reader.read(unit: unit, architecture: .arm64)
        XCTAssertEqual(result.sourceName, "Main")
        XCTAssertEqual(result.architecture, .arm64)
        do { _ = try await reader.read(unit: unit, architecture: .x86_64); XCTFail("No fallback") } catch {}
    }
    func testChangedImageAndWrongReturnedSliceReject() async throws {
        let (app, unit) = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let wrong = snapshot(.x86_64)
        do { _ = try await CodeUnitEntitlementReader(extract: { _,_ in wrong }).read(unit: unit, architecture: .arm64); XCTFail("Wrong returned architecture") } catch {}
        let valid = snapshot(.arm64)
        do {
            _ = try await CodeUnitEntitlementReader(extract: { location,_ in
                try Data("changed".utf8).write(to: location.executableURL); return valid
            }).read(unit: unit, architecture: .arm64)
            XCTFail("Changed file")
        } catch {}
    }
    func testInfoAndPrivacyCapturePreservesTypedPresenceAndFailures() throws {
        let (app, unit) = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let componentID = UUID()
        let info = ComponentInfoDeclarations.capture(unit, componentID: componentID)
        XCTAssertEqual(info.state, .present)
        XCTAssertEqual(try info.values()["CFBundleIdentifier"], .string("example.unit"))
        let missing = ComponentPrivacyDeclarations.capture(unit, componentID: componentID)
        XCTAssertEqual(missing.state, .notPresent)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let url = app.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy")
        try PropertyListSerialization.data(fromPropertyList: ["NSPrivacyTracking":false], format:.binary,options:0).write(to:url)
        let present = ComponentPrivacyDeclarations.capture(unit, componentID: componentID)
        XCTAssertEqual(try present.values()["NSPrivacyTracking"], .boolean(false))
        try Data("not a plist".utf8).write(to:url)
        XCTAssertEqual(ComponentPrivacyDeclarations.capture(unit, componentID: componentID).state, .unavailable)
    }
    func testUnsignedExtractionDoesNotBecomeEmptySuccess() async throws {
        let (app, unit) = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        do {
            _ = try await CodeUnitEntitlementReader(extract: { _,_ in throw SigningMetadataError.unsigned }).read(unit: unit, architecture: .arm64)
            XCTFail("Unsigned must stay unavailable")
        } catch { XCTAssertTrue(error is SigningMetadataError) }
    }
}
