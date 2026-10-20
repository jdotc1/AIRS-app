import Darwin
import Foundation
import XCTest
@testable import AIRSCore

final class ComponentInventoryTests: XCTestCase {
    private func word(_ x: UInt32, little: Bool = true) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: x >> ((little ? $0 : 3 - $0) * 8)) })
    }
    private func thin(cpu: UInt32 = 0x0100000c, subtype: UInt32 = 0, legacy: Bool = false) -> Data {
        var data = Data([0xcf, 0xfa, 0xed, 0xfe])
        for value: UInt32 in [cpu, subtype, 2, 1, legacy ? 16 : 24, 0, 0] { data.append(word(value)) }
        for value: UInt32 in legacy ? [0x24, 16, 0x000c0300, 0] : [0x32, 24, 1, 0x000e0100, 0, 0] { data.append(word(value)) }
        return data
    }
    private func fat() -> Data {
        let arm = thin(), intel = thin(cpu: 0x01000007, subtype: 3, legacy: true)
        var data = Data([0xca,0xfe,0xba,0xbe]); data.append(word(2, little: false))
        for values: [UInt32] in [[0x0100000c,0,4096,UInt32(arm.count),12],[0x01000007,3,8192,UInt32(intel.count),12]] {
            for value in values { data.append(word(value, little: false)) }
        }
        data.append(Data(repeating: 0, count: 4096-data.count)); data.append(arm)
        data.append(Data(repeating: 0, count: 8192-data.count)); data.append(intel)
        return data
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-components-20261020/tests/\(UUID())/Owned.app")
        let files = ["Contents/MacOS/Main": fat(), "Contents/Helpers/intel": thin(cpu: 0x01000007, subtype: 3),
            "Contents/Helpers/arm": thin(), "Contents/XPCServices/Worker.xpc/Contents/MacOS/Worker": thin(),
            "Contents/XPCServices/Worker.xpc/Contents/Frameworks/Nested.framework/Nested": thin(),
            "Contents/Frameworks/Owned.framework/Versions/A/Owned": thin()]
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        for (path, executable) in [("Contents/Info.plist", "Main"), ("Contents/XPCServices/Worker.xpc/Contents/Info.plist", "Worker"),
            ("Contents/XPCServices/Worker.xpc/Contents/Frameworks/Nested.framework/Resources/Info.plist", "Nested"),
            ("Contents/Frameworks/Owned.framework/Versions/A/Resources/Info.plist", "Owned")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": executable, "CFBundleIdentifier": "example.\(executable)", "CFBundleShortVersionString": "1.2"], format: .xml, options: 0).write(to: url)
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Contents/Helpers/escape").path, withDestinationPath: "/bin")
        return root
    }
    func testMixedArchitectureTreeAndDeclarations() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let result = try ComponentInventoryBuilder().build(app)
        XCTAssertEqual(result.components.count, 6)
        let main = try XCTUnwrap(result.components.first { $0.kind == "app" })
        XCTAssertEqual(Set(main.architectures), ["arm64", "x86_64"])
        XCTAssertEqual(main.minimumOSByArchitecture, ["arm64":"14.1.0", "x86_64":"12.3.0"])
        XCTAssertEqual(main.declaredBundleID, "example.Main")
        let worker = try XCTUnwrap(result.components.first { $0.kind == "xpc" })
        XCTAssertEqual(worker.parentID, main.id)
        let nested = try XCTUnwrap(result.components.first { $0.relativePath.contains("Nested.framework") })
        XCTAssertEqual(nested.parentID, worker.id)
        XCTAssertTrue(result.scope.exclusions.contains { $0.contains("escape") })
        XCTAssertEqual(result.observedIntelOnly.map(\.relativePath), ["Contents/Helpers/intel"])
        XCTAssertTrue(result.components.first { $0.relativePath == "Contents/Helpers/arm" }?.declaredBundleID == nil)
    }
    func testEachTraversalBudgetRemainsPartial() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        for limits in [BundleDiscovery.Limits(entries: 1), .init(depth: 1), .init(candidates: 1), .init(headerBytes: 4096)] {
            let result = try ComponentInventoryBuilder(limits: limits).build(app)
            XCTAssertEqual(result.scope.completion, .partial)
            XCTAssertFalse(result.scope.issues.isEmpty)
            if limits.entries == 1 { XCTAssertEqual(result.scope.searchedLocations, ["Contents/MacOS", "Contents/Frameworks"]) }
        }
    }
    func testChangedCandidateCannotBecomeMetadataSuccess() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == "Contents/Helpers/arm" })
        try thin(cpu: 0x01000007, subtype: 3).write(to: app.appendingPathComponent(row.relativePath))
        XCTAssertThrowsError(try ComponentMetadataReader().read(row))
    }
    func testMalformedHeadersAndMetadataBudgetStayUnavailable() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var data = thin(); data.replaceSubrange(20..<24, with: word(1_048_577))
        try data.write(to: app.appendingPathComponent("Contents/Helpers/broken"))
        let result = try ComponentInventoryBuilder().build(app)
        let broken = try XCTUnwrap(result.components.first { $0.relativePath.hasSuffix("broken") })
        XCTAssertTrue(broken.architectures.isEmpty)
        XCTAssertFalse(broken.readIssues.isEmpty)
        XCTAssertEqual(result.scope.completion, .partial)
        let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == "Contents/Helpers/arm" })
        XCTAssertThrowsError(try ComponentMetadataReader(maximumHeaderBytes: 8).read(row))
    }
    func testUnknownCPUAndArm64eAreNotUnwindCoverage() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try thin(cpu: 0x12345678, subtype: 9).write(to: app.appendingPathComponent("Contents/Helpers/unknown"))
        try thin(subtype: 2).write(to: app.appendingPathComponent("Contents/Helpers/pac"))
        let result = try ComponentInventoryBuilder().build(app)
        XCTAssertTrue(result.components.first { $0.relativePath.hasSuffix("unknown") }?.architectures.first?.contains("12345678") == true)
        XCTAssertEqual(result.components.first { $0.relativePath.hasSuffix("pac") }?.architectures, ["arm64e"])
        XCTAssertFalse(result.observedIntelOnly.contains { $0.relativePath.hasSuffix("unknown") })
    }
    func testStrictUniversalLayoutAndThinHeaderWidth() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var overlap = fat(); overlap.replaceSubrange(36..<40, with: word(4096, little: false))
        var mismatched = fat(); mismatched.replaceSubrange(8..<12, with: word(0x01000007, little: false))
        let wrongWidth = thin(cpu: 7, subtype: 3)
        var badTools = thin(); badTools.replaceSubrange(52..<56, with: word(1))
        for (name, data) in [("overlap",overlap),("mismatch",mismatched),("width",wrongWidth),("tools",badTools)] {
            let path = "Contents/Helpers/" + name
            try data.write(to: app.appendingPathComponent(path))
            let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == path })
            XCTAssertThrowsError(try ComponentMetadataReader().read(row), name)
        }
    }
    func testNestedImagesCannotBorrowLabelsFromMissingOrMismatchedExecutable() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let path = "Contents/XPCServices/Worker.xpc/Contents/Helpers/Worker"
        try FileManager.default.createDirectory(at: app.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try thin().write(to: app.appendingPathComponent(path))
        let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == path })
        let borrowed = try ComponentMetadataReader().read(row)
        XCTAssertNil(borrowed.declaredBundleID)
        XCTAssertEqual(borrowed.kind, "image")
        let inventory = try ComponentInventoryBuilder().build(app)
        let worker = try XCTUnwrap(inventory.components.first { $0.kind == "xpc" })
        XCTAssertEqual(inventory.components.first { $0.relativePath == path }?.parentID, worker.id)
        let plist = app.appendingPathComponent("Contents/XPCServices/Worker.xpc/Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"example.Worker", "CFBundleShortVersionString":"1.2"], format: .xml, options: 0).write(to: plist)
        let main = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == "Contents/XPCServices/Worker.xpc/Contents/MacOS/Worker" })
        let unavailable = try ComponentMetadataReader().read(main)
        XCTAssertNil(unavailable.declaredBundleID)
        XCTAssertEqual(unavailable.kind, "image")
        XCTAssertFalse(unavailable.readIssues.isEmpty)
    }
    func testContradictoryPlatformCommandsCannotPublishMacMinimum() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var data = thin()
        data.replaceSubrange(16..<20, with: word(2)); data.replaceSubrange(20..<24, with: word(40))
        data.replaceSubrange(40..<44, with: word(2)) // iOS platform, followed by macOS legacy minimum
        for value: UInt32 in [0x24,16,0x000e0000,0] { data.append(word(value)) }
        let path = "Contents/Helpers/contradictory"
        try data.write(to: app.appendingPathComponent(path))
        let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == path })
        XCTAssertThrowsError(try ComponentMetadataReader().read(row))
    }
    func testThin32BigEndianAndLittleEndianFat64Declarations() throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        var thin32 = Data([0xce,0xfa,0xed,0xfe])
        for value: UInt32 in [7,3,2,1,16,0,0x24,16,0x000c0300,0] { thin32.append(word(value)) }
        var big = Data([0xfe,0xed,0xfa,0xcf])
        for value: UInt32 in [0x01000007,3,2,1,16,0,0,0x24,16,0x000c0300,0] { big.append(word(value, little: false)) }
        let image = thin()
        var wide = Data([0xbf,0xba,0xfe,0xca]); wide.append(word(1))
        for value: UInt32 in [0x0100000c,0,4096,0,UInt32(image.count),0,12,0] { wide.append(word(value)) }
        wide.append(Data(repeating: 0, count: 4096-wide.count)); wide.append(image)
        for (name, bytes, architecture) in [("thin32",thin32,"i386"),("big",big,"x86_64"),("fat64",wide,"arm64")] {
            let path = "Contents/Helpers/" + name
            try bytes.write(to: app.appendingPathComponent(path))
            let row = try XCTUnwrap(BundleDiscovery().discover(app).entries.first { $0.relativePath == path })
            let record = try ComponentMetadataReader().read(row)
            XCTAssertEqual(record.architectures, [architecture])
            XCTAssertEqual(record.minimumOSByArchitecture[architecture], architecture == "arm64" ? "14.1.0" : "12.3.0")
        }
    }
    func testCancelledScopeIsNotComplete() async throws {
        let app = try fixture(); defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ComponentInventoryBuilder().build(app)
        }
        let result = try await task.value
        XCTAssertEqual(result.scope.completion, .cancelled)
    }
}
