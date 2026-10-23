import Foundation
import XCTest
@testable import AIRSApp

final class SettingsReviewIsolationTests: XCTestCase {
    @MainActor
    func testExplicitPreviewIsolatesPreferencesAndAllAuditStoresAndRejectsPartialConfiguration() throws {
        let id = UUID().uuidString.lowercased()
        let root = SettingsReviewConfiguration.reviewParent
            .appendingPathComponent("AIRS-settings-visual-\(id)", isDirectory: true)
        let identifier = "dev.airs.settings-review.\(id)"
        let suite = identifier + ".preferences"
        try FileManager.default.createDirectory(at: SettingsReviewConfiguration.reviewParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: suite + ".lumen")?.removePersistentDomain(forName: suite + ".lumen")
        }
        let environment = ["AIRS_SETTINGS_REVIEW": "1", "AIRS_SETTINGS_REVIEW_ROOT": root.path,
                           "AIRS_SETTINGS_REVIEW_SUITE": suite]
        let configuration = try XCTUnwrap(SettingsReviewConfiguration.parse(environment: environment, bundleIdentifier: identifier))
        let defaults = try configuration.preferences()
        defaults.set("/synthetic/original-python", forKey: "pythonExecutablePath")
        let support = root.appendingPathComponent("data", isDirectory: true)
        let workspace = AuditWorkspace(recents: SettingsReviewRecents(), supportRoot: support, preferences: defaults)
        XCTAssertEqual(workspace.pythonPath, "/synthetic/original-python")
        workspace.pythonPath = "/synthetic/changed-python"
        workspace.usesExternalPython = true
        XCTAssertEqual(defaults.string(forKey: "pythonExecutablePath"), "/synthetic/changed-python")
        XCTAssertTrue(defaults.bool(forKey: "usesExternalPython"))
        let locations = workspace.storageLocations
        XCTAssertEqual(locations.boundReviews, support.appendingPathComponent("AIRS/BoundReviews", isDirectory: true))
        XCTAssertEqual(locations.reportLibrary, support.appendingPathComponent("AIRS/ReportLibrary", isDirectory: true))
        XCTAssertEqual(locations.analysisReuse, support.appendingPathComponent("AIRS/AnalysisReuse", isDirectory: true))
        XCTAssertEqual(locations.batchHistory, support.appendingPathComponent("AIRS/BatchHistory", isDirectory: true))
        for key in environment.keys {
            var partial = environment; partial.removeValue(forKey: key)
            XCTAssertThrowsError(try SettingsReviewConfiguration.parse(environment: partial, bundleIdentifier: identifier))
        }
        XCTAssertNotEqual(suite, identifier)
        var ownBundleSuite = environment; ownBundleSuite["AIRS_SETTINGS_REVIEW_SUITE"] = identifier
        XCTAssertThrowsError(try SettingsReviewConfiguration.parse(environment: ownBundleSuite, bundleIdentifier: identifier))
        XCTAssertThrowsError(try SettingsReviewConfiguration.parse(environment: environment, bundleIdentifier: "dev.airs.app"))
        var invalid = environment; invalid["AIRS_SETTINGS_REVIEW_ROOT"] = "/Applications"
        XCTAssertThrowsError(try SettingsReviewConfiguration.parse(environment: invalid, bundleIdentifier: identifier))
        XCTAssertNil(try SettingsReviewConfiguration.parse(environment: [:], bundleIdentifier: "dev.airs.app"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }
}
