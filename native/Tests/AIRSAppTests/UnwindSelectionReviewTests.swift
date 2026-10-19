import Foundation
import XCTest
import AIRSCore
@testable import AIRSApp

final class UnwindSelectionReviewTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    @MainActor
    private func workspace() throws -> AuditWorkspace {
        let url = project.appendingPathComponent("examples/before.audit.json")
        let data = try Data(contentsOf: url)
        let workspace = AuditWorkspace()
        workspace.openValidatedReport(try AuditReport.decode(data), data: data, from: url)
        return workspace
    }

    @MainActor
    func testSearchHidingSelectionCanRevealItWithoutReplacingReport() throws {
        let subject = try workspace()
        let finding = try XCTUnwrap(subject.report?.findings.first)
        subject.selection = .finding(finding.id)
        let revision = subject.reportRevision
        subject.search = "no-such-function-for-selection-review"
        XCTAssertTrue(subject.visibleFindings.isEmpty)
        XCTAssertTrue(subject.selectedFindingIsHidden)
        XCTAssertEqual(subject.selectedFinding?.id, finding.id)
        subject.revealSelectedFinding()
        XCTAssertEqual(subject.search, "")
        XCTAssertEqual(subject.selection, .finding(finding.id))
        XCTAssertFalse(subject.selectedFindingIsHidden)
        XCTAssertEqual(subject.reportRevision, revision)
    }

    @MainActor
    func testVerdictAndSearchRecoveryPreservesExactFindingIdentity() throws {
        let subject = try workspace()
        let finding = try XCTUnwrap(subject.report?.findings.first)
        subject.selection = .finding(finding.id)
        subject.verdictFilter = finding.verdict == .agreement ? .unresolved : .agreement
        subject.search = "no-such-function-for-selection-review"
        XCTAssertTrue(subject.selectedFindingIsHidden)
        subject.revealSelectedFinding()
        XCTAssertEqual(subject.verdictFilter, .all)
        XCTAssertEqual(subject.search, "")
        XCTAssertEqual(subject.selectedFinding?.id, finding.id)
        XCTAssertTrue(subject.visibleFindings.contains { $0.id == finding.id })
    }

    @MainActor
    func testOverviewMissingAndVisibleSelectionsDoNotResetFilters() throws {
        let subject = try workspace()
        subject.search = "retained-query"
        for selection: WorkspaceSelection? in [.overview, .finding("missing-id"), nil] {
            subject.selection = selection
            XCTAssertFalse(subject.selectedFindingIsHidden)
            subject.revealSelectedFinding()
            XCTAssertEqual(subject.search, "retained-query")
            XCTAssertEqual(subject.selection, selection)
        }
        let finding = try XCTUnwrap(subject.report?.findings.first)
        subject.selection = .finding(finding.id)
        subject.search = finding.function.address
        XCTAssertFalse(subject.selectedFindingIsHidden)
        subject.revealSelectedFinding()
        XCTAssertEqual(subject.search, finding.function.address)
    }
}
