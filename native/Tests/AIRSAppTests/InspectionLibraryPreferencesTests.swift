import XCTest
@testable import AIRSApp

final class InspectionLibraryPreferencesTests: XCTestCase {
    func testDefaultRoundTripsAndFailedWriteLeavesPreviousDefaultIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let original = InspectionLibraryPreferences(pinnedBaselineID: UUID())
        try original.write(to: url)
        XCTAssertEqual(try InspectionLibraryPreferences.read(at: url).pinnedBaselineID, original.pinnedBaselineID)
        let invalid = url.appendingPathComponent("cannot-write.json")
        XCTAssertThrowsError(try InspectionLibraryPreferences(pinnedBaselineID: UUID()).write(to: invalid))
        XCTAssertEqual(try InspectionLibraryPreferences.read(at: url).pinnedBaselineID, original.pinnedBaselineID)
    }
    func testUnsupportedOrOversizedPreferencesAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":2}"#.utf8).write(to: url)
        XCTAssertThrowsError(try InspectionLibraryPreferences.read(at: url))
        try Data(repeating: 32, count: 4097).write(to: url)
        XCTAssertThrowsError(try InspectionLibraryPreferences.read(at: url))
    }
}
