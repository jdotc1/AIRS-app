import XCTest
import AIRSCore
import AIRSEntitlements
import EntitlementDiffCore
@testable import AIRSApp
final class ComponentReviewWorkspaceTests: XCTestCase {
    func session() throws -> ComponentReviewSession {
        func inventory() -> ComponentInventory { .init(scope:.init(searchedLocations:["Contents/MacOS"],completion:.partial,exclusions:[],issues:["Owned gap"]),components:[.init(relativePath:"Contents/MacOS/Main",kind:"app",architectures:["arm64"])]) }
        let review = try ComponentComparison.review(previous:inventory(),current:inventory(),architecture:.arm64,entitlementResults:[])
        return try .init(review:review,archiveBytes:ComponentReviewArchive.encode(review),sourceURLs:[URL(fileURLWithPath:"/owned/report.airsreview")],live:nil)
    }
    @MainActor
    func testPairJobStagesWithoutReplacingSessionsAndRejectsStaleResults() async throws {
        let session = try session(), audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        let owner = AIRSFileOpen(hasModal:{false}, componentBuild:{ _,_,_ in session })
        let before = audit.reportRevision
        await owner.compareComponents(previous:URL(fileURLWithPath:"/owned/A.app"),current:URL(fileURLWithPath:"/owned/B.app"),architecture:.arm64,audit:audit,entitlements:entitlements)?.value
        XCTAssertNotNil(owner.componentReview)
        XCTAssertEqual(audit.reportRevision,before)
        owner.closeComponentReview()
        let task = try XCTUnwrap(owner.compareComponents(previous:URL(fileURLWithPath:"/owned/A.app"),current:URL(fileURLWithPath:"/owned/B.app"),architecture:.arm64,audit:audit,entitlements:entitlements))
        entitlements.model.loadExample()
        await task.value
        XCTAssertNil(owner.componentReview)
    }
    @MainActor
    func testPairConfirmationDefersBuildUntilSheetDismissal() async throws {
        let value = try session(), audit = AuditWorkspace(), entitlements = EntitlementsWorkspace()
        var modal = true
        let owner = AIRSFileOpen(hasModal:{modal},componentBuild:{_,_,_ in value})
        owner.componentPairReview = .init(previous:URL(fileURLWithPath:"/owned/A.app"),current:URL(fileURLWithPath:"/owned/B.app"),auditRevision:audit.reportRevision,entitlementRevision:entitlements.model.reportRevision)
        owner.confirmComponentPair(.arm64,audit:audit,entitlements:entitlements)
        XCTAssertNil(owner.componentPairReview)
        XCTAssertNil(owner.componentReview)
        // AppKit may still expose the dismissing owned sheet in onDismiss.
        await owner.componentPairDismissed(audit:audit,entitlements:entitlements)?.value
        modal = false
        XCTAssertNotNil(owner.componentReview)
    }
    func testMetadataChangedAfterBuildRequiresRebuildBeforeEntitlementJoin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-component-review-20261020/stale-info/\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func app(_ name:String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at:url.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:project.appendingPathComponent("fixtures/generated/before.macho"),to:url.appendingPathComponent("Contents/MacOS/Main"))
            try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"Main","CFBundleIdentifier":"owned","CFBundleShortVersionString":"1.0","CFBundleVersion":"1"],format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
            return url
        }
        let a = try app("A"), b = try app("B"), session = try ComponentReviewOperations.build(a,b,.arm64)
        let info = a.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as? [String:Any])
        plist["CFBundleVersion"] = "2"
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:info)
        let updated = try await ComponentReviewOperations.read(session,matchID:session.review.matching.matches[0].id,reader:OwnedUnitReader())
        guard case .unavailable(_,_,let reason) = updated.review.entitlementResults[0] else { return XCTFail("Changed metadata must not join old capture") }
        XCTAssertTrue(reason.contains("rebuild"))
    }
    func testImportedReviewCannotAuthorizeLiveReadsAndArchiveSelectsReview() async throws {
        let session = try session()
        do { _ = try await ComponentReviewOperations.read(session,matchID:session.review.matching.matches[0].id); XCTFail("No live capability") } catch {}
        let archive = try InspectionArchive.decode(session.archiveBytes)
        let id = try XCTUnwrap(archive.attachments.first { $0.kind == ComponentReviewArchive.kind }?.id)
        guard case .componentReview(let value) = try AIRSOpenedReport.attachment(archive,id:id) else { return XCTFail("Review route") }
        XCTAssertEqual(value.previous.id,session.review.previous.id)
    }
}

private struct OwnedUnitReader: CodeUnitSnapshotReading {
    func read(unit:BundleImageProvenance,architecture:Architecture) async throws -> EntitlementSnapshot {
        .init(sourceName:unit.relativePath,signingIdentifier:"owned",architecture:architecture,presence:.dictionaryPresent,entitlements:.init())
    }
}
