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
    func testReadAvailabilityRequiresLivePairCapabilitiesAndRequestedSlice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-availability-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        func app(_ name: String, workerCPU: UInt32) throws -> URL {
            let app = root.appendingPathComponent(name + ".app")
            for (container, executable, cpu) in [("", "Main", UInt32(0x0100000c)), ("Contents/XPCServices/Worker.xpc/", "Worker", workerCPU)] {
                let contents = app.appendingPathComponent(container + "Contents")
                try FileManager.default.createDirectory(at:contents.appendingPathComponent("MacOS"),withIntermediateDirectories:true)
                var image = Data([0xcf,0xfa,0xed,0xfe])
                for word: UInt32 in [cpu, cpu == 0x01000007 ? 3 : 0, 2, 1, 24, 0, 0, 0x32, 24, 1, 0x000e0000, 0, 0] {
                    image.append(contentsOf:(0..<4).map { UInt8(truncatingIfNeeded:word >> ($0 * 8)) })
                }
                try image.write(to:contents.appendingPathComponent("MacOS/" + executable))
                try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":executable,"CFBundleIdentifier":"owned." + executable,"CFBundleVersion":"1"],format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
            }
            return app
        }
        let previous = try app("Previous",workerCPU:0x0100000c), current = try app("Current",workerCPU:0x01000007)
        let value = try ComponentReviewOperations.build(previous,current,.arm64)
        let main = try XCTUnwrap(value.review.matching.matches.first { match in
            value.review.previous.components.first { $0.id == match.previousID }?.kind == "app"
        })
        let ready = ComponentReviewOperations.readAvailability(value, matchID: main.id)
        XCTAssertTrue(ready.available)
        XCTAssertTrue(ready.reason.contains("arm64"))
        XCTAssertFalse(ComponentReviewOperations.readAvailability(value, matchID: main.id, busy: true).available)
        XCTAssertFalse(ComponentReviewOperations.readAvailability(value, matchID: UUID()).available)
        func session(_ live: [LiveComponentInventory]?) throws -> ComponentReviewSession {
            try .init(review:value.review,archiveBytes:value.archiveBytes,sourceURLs:value.sourceURLs,live:live)
        }
        for previousMissing in [true,false] {
            let broken = ComponentMatch(id:main.id,previousID:previousMissing ? nil : main.previousID,currentID:previousMissing ? main.currentID : nil,relation:.sameLocation,reasons:[])
            let review = ComponentReview(previous:value.review.previous,current:value.review.current,
                matching:.init(matches:[broken],previousScope:value.review.previous.scope,currentScope:value.review.current.scope),
                architecture:.arm64,entitlementResults:[],previousDeclarations:[],currentDeclarations:[])
            let malformed = try ComponentReviewSession(review:review,archiveBytes:value.archiveBytes,sourceURLs:value.sourceURLs,live:value.live)
            XCTAssertTrue(ComponentReviewOperations.readAvailability(malformed,matchID:main.id).reason.contains("identities"))
        }
        let imported = try session(nil)
        XCTAssertTrue(ComponentReviewOperations.readAvailability(imported,matchID:main.id).reason.contains("Imported"))
        let live = try XCTUnwrap(value.live)
        XCTAssertFalse(ComponentReviewOperations.readAvailability(try session([live[0]]),matchID:main.id).available)
        let missingPrevious = LiveComponentInventory(inventory:live[0].inventory,units:[:])
        let missingCurrent = LiveComponentInventory(inventory:live[1].inventory,units:[:])
        for capabilities in [[missingPrevious,live[1]], [live[0],missingCurrent]] {
            let unavailable = try session(capabilities)
            XCTAssertTrue(ComponentReviewOperations.readAvailability(unavailable,matchID:main.id).reason.contains("capability"))
            do { _ = try await ComponentReviewOperations.read(unavailable,matchID:main.id,reader:ForbiddenUnitReader()); XCTFail("Missing capability must refuse") } catch {}
        }
        let worker = try XCTUnwrap(value.review.matching.matches.first { match in
            value.review.previous.components.first { $0.id == match.previousID }?.relativePath.contains("Worker") == true
        })
        let unsupported = ComponentReviewOperations.readAvailability(value,matchID:worker.id)
        XCTAssertFalse(unsupported.available)
        XCTAssertTrue(unsupported.reason.contains("arm64"))
        let updated = try await ComponentReviewOperations.read(value,matchID:worker.id,reader:ForbiddenUnitReader())
        guard case .unavailable(_,let architecture,let reason) = updated.review.entitlementResults.first(where: { $0.matchID == worker.id }) else { return XCTFail("Missing slice remains explicit unavailable evidence") }
        XCTAssertEqual(architecture,.arm64)
        XCTAssertEqual(reason,unsupported.reason)
        let archive = try InspectionArchive.decode(updated.archiveBytes)
        let attachment = try XCTUnwrap(archive.attachments.first { $0.kind == ComponentReviewArchive.kind })
        guard case .componentReview(let reopened) = try AIRSOpenedReport.attachment(archive,id:attachment.id) else { return XCTFail("Archive route") }
        XCTAssertEqual(reopened.entitlementResults.count,value.review.matching.matches.count)
        guard case .unavailable(_,_,let reopenedReason) = reopened.entitlementResults.first(where: { $0.matchID == worker.id }) else { return XCTFail("Missing slice result survived archive") }
        XCTAssertEqual(reopenedReason,unsupported.reason)
        for match in value.review.matching.matches where match.relation != .sameLocation {
            XCTAssertFalse(ComponentReviewOperations.readAvailability(value,matchID:match.id).available)
        }
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
    func testMissingPrincipalReviewRetainsRootDeclarationsThroughArchiveWithoutLiveAuthority() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("build/rea5589/review-fixtures/\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "owned.resources", "CFBundleShortVersionString": "1.0"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try PropertyListSerialization.data(fromPropertyList: ["NSPrivacyTracking": false], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy"))
            return url
        }
        let session = try ComponentReviewOperations.build(app("A"), app("B"), .arm64)
        let id = try XCTUnwrap(session.review.previous.components.first?.id)
        XCTAssertEqual(session.review.previous.components.count, 1)
        XCTAssertTrue(session.live?[0].units.isEmpty == true)
        let match = try XCTUnwrap(session.review.matching.matches.first)
        XCTAssertEqual(match.relation, .sameLocation)
        let availability = ComponentReviewOperations.readAvailability(session, matchID: match.id)
        XCTAssertFalse(availability.available)
        XCTAssertTrue(availability.reason.contains("live discovered file capability"))
        XCTAssertEqual(session.review.previousDeclarations.first { $0.componentID == id && $0.category == .info }?.state, .present)
        XCTAssertEqual(session.review.previousDeclarations.first { $0.componentID == id && $0.category == .privacy }?.state, .present)
        XCTAssertEqual(session.review.previousDeclarations.first { $0.componentID == id && $0.category == .loadCommands }?.state, .unavailable)
        let archive = try InspectionArchive.decode(session.archiveBytes)
        let attachment = try XCTUnwrap(archive.attachments.first { $0.kind == ComponentReviewArchive.kind })
        guard case .componentReview(let value) = try AIRSOpenedReport.attachment(archive, id: attachment.id) else { return XCTFail("Review route") }
        XCTAssertEqual(value.previousDeclarations.first { $0.componentID == id && $0.category == .info }?.bytes, session.review.previousDeclarations.first { $0.componentID == id && $0.category == .info }?.bytes)
        do { _ = try await ComponentReviewOperations.read(session, matchID: match.id, reader: ForbiddenUnitReader()); XCTFail("Declaration record cannot authorize entitlement reads") }
        catch AIRSCore.ReportError.invalidContents(let reason) { XCTAssertEqual(reason, availability.reason) }
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

private struct ForbiddenUnitReader: CodeUnitSnapshotReading {
    func read(unit:BundleImageProvenance,architecture:Architecture) async throws -> EntitlementSnapshot {
        XCTFail("Availability refusal must precede extraction")
        throw InspectionArchiveError.invalid
    }
}
