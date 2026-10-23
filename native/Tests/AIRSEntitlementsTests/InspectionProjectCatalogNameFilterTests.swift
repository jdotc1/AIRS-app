import Foundation
import XCTest
@testable import AIRSEntitlements

final class InspectionProjectCatalogNameFilterTests: XCTestCase {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-catalog-name-filter").path
        let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func keep(_ project: InspectionProject, at root: URL) throws -> URL {
        let directory = root.appendingPathComponent("Projects/" + project.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("manifest.json")
        try project.data().write(to: path)
        return path
    }
    private func catalog(_ root: URL, query: String? = nil) async throws -> [String: Any] {
        var arguments = ["catalog", "--store", root.path]
        if let query { arguments += ["--name-contains", query] }
        let data = try await PortableProjectCommand.run(arguments: arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testNameFilterUsesLiteralFoldedNamesAndLeavesDefaultShapeUnchanged() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let wanted = InspectionProject(name: "Café Release"), other = InspectionProject(name: "Different project")
        _ = try keep(wanted, at: root); _ = try keep(other, at: root)
        let unfiltered = try await catalog(root)
        XCTAssertNil(unfiltered["selection"])
        XCTAssertEqual(unfiltered["projectCount"] as? Int, 2)
        XCTAssertEqual(Set(unfiltered.keys), Set(["format", "schemaVersion", "store", "projectCount", "readableCount", "unreadableCount", "evidenceValidated", "historicalOutcomesResolved", "queueRestored", "atomicSnapshot", "projects"]))
        for query in ["CAFE", "fé rel"] {
            let result = try await catalog(root, query: query)
            let rows = try XCTUnwrap(result["projects"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["projectID"] as? String, wanted.id.uuidString)
            XCTAssertEqual(rows.first?["name"] as? String, "Café Release")
            XCTAssertEqual((result["selection"] as? [String: Any])?["nameContains"] as? String, query)
        }
        let literal = try await catalog(root, query: ".*")
        XCTAssertEqual(literal["projectCount"] as? Int, 0)
    }
    func testNameFilterRetainsUnreadableRowsAndExplainsExcludedCountsWithoutMutation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let wanted = InspectionProject(name: "Review target"), excluded = InspectionProject(name: "Other")
        let path = try keep(wanted, at: root), excludedPath = try keep(excluded, at: root)
        let original = try Data(contentsOf: path), excludedOriginal = try Data(contentsOf: excludedPath)
        let bad = UUID(), directory = root.appendingPathComponent("Projects/" + bad.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let broken = directory.appendingPathComponent("manifest.json")
        try Data("broken".utf8).write(to: broken)
        let result = try await catalog(root, query: "target")
        let rows = try XCTUnwrap(result["projects"] as? [[String: Any]])
        XCTAssertEqual(result["projectCount"] as? Int, 2)
        XCTAssertEqual(result["readableCount"] as? Int, 1)
        XCTAssertEqual(result["unreadableCount"] as? Int, 1)
        XCTAssertNotNil(rows.first { $0["projectID"] as? String == bad.uuidString }?["issue"])
        XCTAssertEqual(rows.compactMap { $0["projectID"] as? String }, rows.compactMap { $0["projectID"] as? String }.sorted())
        let selection = try XCTUnwrap(result["selection"] as? [String: Any])
        XCTAssertEqual(selection["examinedProjectCount"] as? Int, 3)
        XCTAssertEqual(selection["excludedReadableCount"] as? Int, 1)
        XCTAssertEqual(selection["unreadableRowsRetained"] as? Bool, true)
        for flag in ["evidenceValidated", "historicalOutcomesResolved", "queueRestored", "atomicSnapshot"] {
            XCTAssertEqual(result[flag] as? Bool, false)
        }
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(try Data(contentsOf: excludedPath), excludedOriginal)
        XCTAssertEqual(try Data(contentsOf: broken), Data("broken".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lease").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Evidence").path))
    }
    func testNameFilterBoundsValidationOperationIsolationAndCancellation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        for query in ["", " \t ", "a\nb", "a\0b", String(repeating: "é", count: 129)] {
            do {
                _ = try await catalog(missing, query: query)
                XCTFail("Invalid filter accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Name filter")) }
        }
        let maximum = try await catalog(root, query: String(repeating: "é", count: 128))
        XCTAssertEqual(maximum["projectCount"] as? Int, 0)
        for arguments in [
            ["preview", "--store", root.path, "--project", UUID().uuidString, "--name-contains", "x"],
            ["catalog", "--store", root.path, "--name-contains", "x", "--name-contains", "y"],
            ["catalog", "--store", root.path, "--name-contains"]
        ] {
            do { _ = try await PortableProjectCommand.run(arguments: arguments); XCTFail("Invalid arguments accepted") }
            catch {}
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PortableProjectCommand.run(arguments: ["catalog", "--store", missing.path, "--name-contains", "valid"])
        }
        do { _ = try await task.value; XCTFail("Cancelled query returned output") }
        catch is CancellationError {} catch { XCTFail("Cancellation relabeled: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
