import XCTest
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp

final class InspectionSummaryTests: XCTestCase {
    func testRecordedContextAndLegacyUnknownAreReadableWithoutLosingDifferences() throws {
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let document = try InspectionDocument(snapshot: pair.previous,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000), producerVersion: "0.2.0-test")
        let context = InspectionCaptureContext(document: document, data: try InspectionDocumentCodec.encode(document), label: "Release A")
        let report = try EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current)
        let text = InspectionSummary.text(report: report, contexts: [.previous: context])
        XCTAssertTrue(text.contains("Previous: Release A"))
        XCTAssertTrue(text.contains("Current: capture metadata unavailable"))
        XCTAssertTrue(text.hasSuffix(report.text()))
        XCTAssertTrue(text.contains("not effective permissions"))
        XCTAssertTrue(text.contains("Original binary not retained"))
    }
}
