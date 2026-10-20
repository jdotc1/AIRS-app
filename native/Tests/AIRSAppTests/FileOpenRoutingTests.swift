import Foundation
import XCTest
import AIRSCore
import EntitlementDiffCore
@testable import AIRSApp

private actor RoutingGate {
    private var continuation: CheckedContinuation<AIRSOpenedReport, Error>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func read() async throws -> AIRSOpenedReport {
        try await withCheckedThrowingContinuation {
            continuation = $0; startedWaiter?.resume(); startedWaiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish(_ result: Result<AIRSOpenedReport, Error>) {
        continuation?.resume(with: result); continuation = nil
    }
}

@MainActor private final class RoutingRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] = []
    func noteRecentDocument(_ url: URL) { recentDocumentURLs.append(url) }
    func clearRecentDocuments() { recentDocumentURLs = [] }
}

final class FileOpenRoutingTests: XCTestCase {
    private var project: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var auditURL: URL { project.appendingPathComponent("examples/before.audit.json") }
    private var entitlementURL: URL { project.appendingPathComponent("fixtures/entitlements/inspector-report.json") }

    @MainActor
    func testCancelledReaderFailureDoesNotPresentError() async throws {
        let gate = RoutingGate()
        let router = AIRSFileOpen(read: { _ in try await gate.read() }, hasModal: { false })
        let audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let task = try XCTUnwrap(router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        await gate.started()
        router.cancel()
        await gate.finish(.failure(CocoaError(.fileReadCorruptFile)))
        await task.value
        XCTAssertNil(router.errorMessage, "A late error from cancelled work must not surface as a new failure")
        XCTAssertFalse(router.isBusy)
        XCTAssertNil(audit.report)
    }

    func testSchemasSelectExistingValidatorsAndPreserveOriginalBytes() throws {
        let bytes = try Data(contentsOf: auditURL)
        guard case .audit(let audit, let original) = try AIRSOpenedReport.parse(bytes) else { return XCTFail("Expected audit") }
        XCTAssertEqual(original, bytes)
        XCTAssertEqual(audit.reportKind, "airs.audit")
        let pair = ExampleSnapshots.structuredPair(architecture: .arm64)
        let data = try EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current).jsonData()
        guard case .entitlements(let saved) = try AIRSOpenedReport.parse(data) else { return XCTFail("Expected entitlements") }
        XCTAssertEqual(saved.current.entitlements, pair.current.entitlements)
    }

    func testUnknownMixedAndMalformedReportsNeverChooseAnotherParser() throws {
        let invalid = [
            #"{"schema_version":1,"report_kind":"airs.comparison"}"#,
            #"{"schema_version":2,"report_kind":"airs.audit"}"#,
            #"{"schemaVersion":2,"tool":"EntitlementDiff"}"#,
            #"{"schemaVersion":1,"tool":"Other"}"#,
            #"{"schema_version":1,"report_kind":"airs.audit","schemaVersion":1,"tool":"EntitlementDiff"}"#,
            #"{"schema_version":1,"report_kind":"airs.audit","tool":null}"#,
            #"{"schema_version":1,"report_kind":"airs.audit"}"#,
            #"{"schemaVersion":1,"tool":"EntitlementDiff"}"#,
            #"{"value":"not a report"}"#, "{", "[]"
        ]
        for text in invalid { XCTAssertThrowsError(try AIRSOpenedReport.parse(Data(text.utf8)), text) }
        // The shared 64 MiB envelope does not widen the entitlement parser's 8 MiB ceiling.
        var largeEntitlement = Data(#"{"schemaVersion":1,"tool":"EntitlementDiff","padding":""#.utf8)
        largeEntitlement.append(Data(repeating: 0x61, count: SavedReport.maximumBytes))
        largeEntitlement.append(Data("\"}".utf8))
        XCTAssertThrowsError(try AIRSOpenedReport.parse(largeEntitlement)) { error in
            guard case SavedReportError.limit = error else { return XCTFail("Wrong limit: \(error)") }
        }
    }

    @MainActor
    func testAuditOpenPreservesEntitlementSessionAndRecordsRecentOnlyAfterSuccess() async throws {
        let recents = RoutingRecents()
        let actualAudit = AuditWorkspace(recents: recents)
        let entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        entitlements.loadExample()
        let revision = entitlements.model.reportRevision
        navigation.showsEntitlements = true
        let router = AIRSFileOpen(hasModal: { false })
        let pending = try XCTUnwrap(router.open([auditURL], audit: actualAudit, entitlements: entitlements, navigation: navigation))
        XCTAssertTrue(recents.recentDocumentURLs.isEmpty)
        XCTAssertTrue(navigation.showsEntitlements, "Do not change workspace before validation")
        await pending.value
        XCTAssertFalse(navigation.showsEntitlements)
        XCTAssertNotNil(actualAudit.report)
        XCTAssertEqual(recents.recentDocumentURLs, [auditURL])
        XCTAssertEqual(entitlements.model.reportRevision, revision)
    }

    @MainActor
    func testEntitlementOpenStagesReviewPreservesAuditAndProtectsAdoptedSource() async throws {
        let audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let bytes = try Data(contentsOf: auditURL)
        audit.openValidatedReport(try AuditReport.decode(bytes), data: bytes, from: auditURL)
        let auditRevision = audit.reportRevision
        entitlements.loadExample()
        let original = entitlements.model.reportRevision
        let router = AIRSFileOpen(hasModal: { false })
        await router.open([entitlementURL], audit: audit, entitlements: entitlements, navigation: navigation)?.value
        XCTAssertTrue(navigation.showsEntitlements)
        XCTAssertNotNil(entitlements.savedReport)
        XCTAssertEqual(entitlements.model.reportRevision, original, "Review must precede adoption")
        XCTAssertEqual(audit.reportRevision, auditRevision)
        entitlements.openSavedComparison()
        XCTAssertTrue(entitlements.model.previous.snapshot?.isSavedBaseline == true)
        XCTAssertTrue(entitlements.protectedInputs.contains(entitlementURL))
        XCTAssertNotEqual(entitlements.model.reportRevision, original)
    }

    @MainActor
    func testFailurePreservesBothSessionsAndNavigation() async throws {
        let recents = RoutingRecents(), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let audit = AuditWorkspace(recents: recents)
        let bytes = try Data(contentsOf: auditURL)
        audit.openValidatedReport(try AuditReport.decode(bytes), data: bytes, from: auditURL)
        entitlements.loadExample()
        let ar = audit.reportRevision, er = entitlements.model.reportRevision
        navigation.showsEntitlements = true
        let router = AIRSFileOpen(read: { _ in try AIRSOpenedReport.parse(Data(#"{"schema_version":1,"report_kind":"airs.comparison"}"#.utf8)) }, hasModal: { false })
        await router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation)?.value
        XCTAssertNotNil(router.errorMessage)
        XCTAssertEqual(audit.reportRevision, ar)
        XCTAssertEqual(entitlements.model.reportRevision, er)
        XCTAssertTrue(navigation.showsEntitlements)
        XCTAssertEqual(recents.recentDocumentURLs, [auditURL])
    }

    @MainActor
    func testBusyRejectsSecondOpenAndCancelledLateSuccessIsNotPublished() async throws {
        let gate = RoutingGate(), audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let router = AIRSFileOpen(read: { _ in try await gate.read() }, hasModal: { false })
        let task = try XCTUnwrap(router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        await gate.started()
        XCTAssertNil(router.open([entitlementURL], audit: audit, entitlements: entitlements, navigation: navigation))
        XCTAssertTrue(router.status.contains("not opened"))
        router.cancel()
        XCTAssertTrue(router.blocksActions)
        await gate.finish(.success(try AIRSOpenedReport.parse(Data(contentsOf: auditURL))))
        await task.value
        XCTAssertNil(audit.report)
        XCTAssertNil(entitlements.savedReport)
        XCTAssertFalse(router.isBusy)
        XCTAssertNil(router.errorMessage)
    }

    @MainActor
    func testChangedReportRevisionRejectsLatePublication() async throws {
        for changeAudit in [false, true] {
            let gate = RoutingGate(), audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
            let router = AIRSFileOpen(read: { _ in try await gate.read() }, hasModal: { false })
            let task = try XCTUnwrap(router.open([entitlementURL], audit: audit, entitlements: entitlements, navigation: navigation))
            await gate.started()
            if changeAudit {
                let data = try Data(contentsOf: auditURL)
                audit.openValidatedReport(try AuditReport.decode(data), data: data, from: auditURL)
            } else { entitlements.loadExample() }
            await gate.finish(.success(try AIRSOpenedReport.parse(Data(contentsOf: entitlementURL))))
            await task.value
            XCTAssertNil(entitlements.savedReport)
            XCTAssertFalse(navigation.showsEntitlements)
            XCTAssertTrue(router.status.contains("Workspace changed"))
        }
    }

    @MainActor
    func testModalReviewAndInvalidURLsRejectBeforeReading() throws {
        let audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let failRead: @Sendable (URL) async throws -> AIRSOpenedReport = { _ in XCTFail("Must not read"); throw CocoaError(.fileReadUnknown) }
        let router = AIRSFileOpen(read: failRead, hasModal: { false })
        for urls in [[], [auditURL, entitlementURL], [URL(string: "https://example.com/report.json")!], [URL(string: "file://remote/report.json")!]] {
            XCTAssertNil(router.open(urls, audit: audit, entitlements: entitlements, navigation: navigation))
            XCTAssertNotNil(router.errorMessage)
            router.errorMessage = nil
        }
        let modal = AIRSFileOpen(read: failRead, hasModal: { true })
        XCTAssertNil(modal.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        let pair = ExampleSnapshots.pair(architecture: .arm64)
        let saved = try SavedReport.parse(EntitlementDiffCore.ComparisonReport(previous: pair.previous, current: pair.current).jsonData())
        entitlements.reviewValidatedReport(saved, from: entitlementURL)
        XCTAssertNil(router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        entitlements.cancelReview()
        audit.showingError = true
        XCTAssertNil(router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        XCTAssertNil(audit.report)
    }

    @MainActor
    func testQuitWaitsForReadAndResumeAcceptsNextOpen() async throws {
        let gate = RoutingGate(), audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let router = AIRSFileOpen(read: { _ in try await gate.read() }, hasModal: { false })
        let task = try XCTUnwrap(router.open([auditURL], audit: audit, entitlements: entitlements, navigation: navigation))
        await gate.started()
        let quitting = Task { await router.finishBeforeQuit() }
        while !router.isTerminating { await Task.yield() }
        XCTAssertTrue(router.blocksActions)
        await gate.finish(.success(try AIRSOpenedReport.parse(Data(contentsOf: auditURL))))
        await task.value; await quitting.value
        XCTAssertNil(audit.report)
        XCTAssertFalse(router.isBusy)
        router.resumeAfterCancelledQuit()
        XCTAssertFalse(router.blocksActions)
    }

    @MainActor
    func testDelegateHoldsOneColdStartEventAndRejectsMultiple() async throws {
        let audit = AuditWorkspace(recents: RoutingRecents()), entitlements = EntitlementsWorkspace(), navigation = AIRSNavigation()
        let report = try AIRSOpenedReport.parse(Data(contentsOf: entitlementURL))
        let router = AIRSFileOpen(read: { _ in report }, hasModal: { false })
        let delegate = AIRSApplicationDelegate()
        delegate.receiveOpenURLs([entitlementURL])
        delegate.configureFileOpening(audit: audit, entitlements: entitlements, navigation: navigation, fileOpen: router)
        for _ in 0..<100 { if !router.isBusy { break }; await Task.yield() }
        XCTAssertNotNil(entitlements.savedReport)
        entitlements.cancelReview()
        let second = AIRSApplicationDelegate()
        second.receiveOpenURLs([auditURL]); second.receiveOpenURLs([entitlementURL])
        second.configureFileOpening(audit: audit, entitlements: entitlements, navigation: navigation, fileOpen: router)
        XCTAssertNotNil(router.errorMessage)
        XCTAssertNil(audit.report)
        XCTAssertNil(entitlements.savedReport)
    }
}
