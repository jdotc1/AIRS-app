import XCTest
@testable import AIRSEntitlements

final class ProjectStoreDirectoryBudgetTests:XCTestCase {
    func testUnrelatedImmediateEntriesExhaustBudgetExplicitly() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let projects=root.appendingPathComponent("Projects")
        for index in 0..<128 {try Data().write(to:projects.appendingPathComponent("unrelated-\(index)"))}
        let store=InspectionProjectStore(root:root)
        let boundary=try await store.entries()
        XCTAssertTrue(boundary.isEmpty)
        try Data().write(to:projects.appendingPathComponent("one-too-many"))
        do {
            _=try await store.entries();XCTFail("Directory budget must refuse instead of returning a partial list")
        } catch {XCTAssertTrue(error.localizedDescription.contains("directory entry limit"))}
        do {
            _=try await store.create(name:"Refused");XCTFail("Creation must share the bounded directory admission")
        } catch {XCTAssertTrue(error.localizedDescription.contains("directory entry limit"))}
    }

    func testNormalAndUnreadableUUIDRowsRemainAndTraversalIsShallow() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let store=InspectionProjectStore(root:root)
        let project=try await store.create(name:"Retained")
        let brokenID=UUID(),projects=root.appendingPathComponent("Projects")
        // A UUID-named non-directory remains an explicit unreadable row.
        try Data().write(to:projects.appendingPathComponent(brokenID.uuidString))
        let nested=projects.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:false)
        for index in 0..<129 {try Data().write(to:nested.appendingPathComponent("nested-\(index)"))}
        let entries=try await store.entries()
        XCTAssertEqual(Set(entries.map(\.id)),Set([project.id,brokenID]))
        XCTAssertEqual(entries.first(where:{$0.id == project.id})?.project?.name,"Retained")
        XCTAssertNil(entries.first(where:{$0.id == project.id})?.issue)
        XCTAssertNotNil(entries.first(where:{$0.id == brokenID})?.issue)
    }

    func testConfiguredProjectCapacityAndOverflowSafeEntryBudget() async throws {
        let root=try folder();defer {try? FileManager.default.removeItem(at:root)}
        let projects=root.appendingPathComponent("Projects")
        let store=InspectionProjectStore(root:root,maximumProjects:65)
        for _ in 0..<65 {
            try FileManager.default.createDirectory(at:projects.appendingPathComponent(UUID().uuidString),withIntermediateDirectories:false)
        }
        // 129 immediate entries fit the configured 130-entry budget; a fixed
        // catalog-style 128 cap would incorrectly reject this custom capacity.
        for index in 0..<64 {try Data().write(to:projects.appendingPathComponent("unrelated-\(index)"))}
        let accepted=try await store.entries()
        XCTAssertEqual(accepted.count,65)
        XCTAssertTrue(accepted.allSatisfy{$0.project == nil && $0.issue != nil})
        try FileManager.default.createDirectory(at:projects.appendingPathComponent(UUID().uuidString),withIntermediateDirectories:false)
        do {_=try await store.entries();XCTFail("Configured UUID capacity must refuse")}
        catch {XCTAssertTrue(error.localizedDescription.contains("retention is full"))}
        // An extreme caller-provided capacity cannot trap during budget arithmetic.
        let large=InspectionProjectStore(root:root,maximumProjects:Int.max)
        let largeEntries=try await large.entries()
        XCTAssertEqual(largeEntries.count,66)
    }

    private func folder() throws -> URL {
        let base=ProcessInfo.processInfo.environment["AIRS_TEST_OUTPUT_ROOT"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory
        let root=base.appendingPathComponent("AIRS-source-tests/\(UUID())/project-directory-budget").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Projects"),withIntermediateDirectories:true)
        return root
    }
}
