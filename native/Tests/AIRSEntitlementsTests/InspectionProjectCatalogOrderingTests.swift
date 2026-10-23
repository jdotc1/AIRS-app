import Foundation
import XCTest
@testable import AIRSEntitlements

final class InspectionProjectCatalogOrderingTests: XCTestCase {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-catalog-ordering-tests").path
        let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func keep(_ project: InspectionProject, at root: URL) throws {
        let directory = root.appendingPathComponent("Projects/" + project.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try project.data().write(to: directory.appendingPathComponent("manifest.json"))
    }
    private func catalog(_ root: URL, options: [String] = []) async throws -> [String: Any] {
        let data = try await PortableProjectCommand.run(arguments: ["catalog", "--store", root.path] + options)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testNameOrderUsesOriginalBytesUUIDTiesAndUnreadableRowsLast() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Zulu", "Alpha", "Alpha", "alpha", "é", "e\u{301}"]
        let projects = names.map { InspectionProject(name: $0) }
        for project in projects { try keep(project, at: root) }
        let unreadable = [UUID(), UUID()]
        for id in unreadable {
            // A UUID entry without a readable manifest still has a catalog issue.
            try Data("broken".utf8).write(to: root.appendingPathComponent("Projects/" + id.uuidString))
        }
        let result = try await catalog(root, options: ["--sort", "name"])
        let rows = try XCTUnwrap(result["projects"] as? [[String: Any]])
        let tied = [projects[1], projects[2]].sorted { $0.id.uuidString < $1.id.uuidString }
        let expected = tied + [projects[0], projects[3], projects[5], projects[4]]
        XCTAssertEqual(rows.compactMap { $0["projectID"] as? String },
                       expected.map { $0.id.uuidString } + unreadable.map(\.uuidString).sorted())
        XCTAssertEqual(rows.prefix(projects.count).compactMap { $0["name"] as? String }.map { Array($0.utf8) },
                       expected.map { Array($0.name.utf8) })
        XCTAssertTrue(rows.suffix(2).allSatisfy { $0["issue"] != nil && $0["name"] == nil })
        XCTAssertEqual(result["sort"] as? String, "name")
        XCTAssertEqual(result["unreadableCount"] as? Int, 2)
    }
    func testDefaultShapeAndUUIDOrderRemainAndSelectionCountsSurviveOrdering() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = [InspectionProject(name: "z target"), InspectionProject(name: "a TARGET"), InspectionProject(name: "Excluded")]
        for project in projects { try keep(project, at: root) }
        let unreadable = UUID()
        try Data().write(to: root.appendingPathComponent("Projects/" + unreadable.uuidString))
        let baseline = try await catalog(root)
        XCTAssertEqual(Set(baseline.keys), Set(["format", "schemaVersion", "store", "projectCount", "readableCount", "unreadableCount", "evidenceValidated", "historicalOutcomesResolved", "queueRestored", "atomicSnapshot", "projects"]))
        let baselineRows = try XCTUnwrap(baseline["projects"] as? [[String: Any]])
        XCTAssertEqual(baselineRows.compactMap { $0["projectID"] as? String },
                       (projects.map { $0.id.uuidString } + [unreadable.uuidString]).sorted())
        let selected = try await catalog(root, options: ["--name-contains", "target", "--sort", "name"])
        let rows = try XCTUnwrap(selected["projects"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["projectID"] as? String },
                       [projects[1].id.uuidString, projects[0].id.uuidString, unreadable.uuidString])
        XCTAssertEqual(selected["projectCount"] as? Int, 3)
        XCTAssertEqual(selected["readableCount"] as? Int, 2)
        XCTAssertEqual(selected["unreadableCount"] as? Int, 1)
        let selection = try XCTUnwrap(selected["selection"] as? [String: Any])
        XCTAssertEqual(selection["examinedProjectCount"] as? Int, 4)
        XCTAssertEqual(selection["excludedReadableCount"] as? Int, 1)
        XCTAssertEqual(selection["unreadableRowsRetained"] as? Bool, true)
    }
    func testSortRejectsUnknownDuplicateMissingAndOtherOperationArguments() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("uncreated").path
        var invalid = [
            ["catalog", "--store", missing, "--sort", "updated"],
            ["catalog", "--store", missing, "--sort", "Name"],
            ["catalog", "--store", missing, "--sort"],
            ["catalog", "--store", missing, "--sort", "name", "--sort", "name"]
        ]
        for operation in ["preview", "export", "inventory", "reconstruct"] {
            invalid.append([operation, "--sort", "name"])
        }
        for arguments in invalid {
            do {
                _ = try await PortableProjectCommand.run(arguments: arguments)
                XCTFail("Invalid sorting arguments accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains(PortableProjectCommand.usage)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }
}
