import XCTest
import CryptoKit
import AIRSCore
@testable import AIRSEntitlements

final class ComponentInventoryArchiveTests: XCTestCase {
    func fixture() -> ComponentInventory {
        .init(scope: .init(searchedLocations: ["Contents/MacOS"], completion: .partial,
            exclusions: ["Contents/Helpers/link"], issues: ["Directory unreadable"]), components: [
                .init(relativePath: "Contents/MacOS/Main", kind: "app", architectures: ["arm64", "x86_64"], minimumOSByArchitecture: ["arm64":"14.0.0"], readIssues: ["Intel minimum unavailable"])])
    }
    func testInventoryRoundTripsThroughArchiveWithScopeAndByteIdentity() throws {
        let inventory = fixture(), archiveBytes = try ComponentInventoryDocumentCodec.archive(inventory)
        let archive = try InspectionArchive.decode(archiveBytes)
        let attachment = try XCTUnwrap(archive.attachments.first)
        XCTAssertEqual(try archive.validation(for: attachment.id), .supported)
        let reopened = try ComponentInventoryDocumentCodec.decode(attachment.bytes)
        XCTAssertEqual(reopened.id, inventory.id)
        XCTAssertEqual(reopened.scope.completion, .partial)
        XCTAssertEqual(reopened.scope.exclusions, inventory.scope.exclusions)
        XCTAssertEqual(reopened.components[0].architectures, ["arm64", "x86_64"])
        XCTAssertEqual(try InspectionArchive.decode(archive.encode()).attachments[0].bytes, attachment.bytes)
        XCTAssertEqual(archive.components[0].id, inventory.components[0].id)
    }
    func testFutureVersionDuplicatesOversizedReferencesAndSourcePathsReject() throws {
        let encoded = try ComponentInventoryDocumentCodec.encode(fixture())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try ComponentInventoryDocumentCodec.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1
        object["sourceURL"] = "/private/application.app"
        XCTAssertThrowsError(try ComponentInventoryDocumentCodec.decode(JSONSerialization.data(withJSONObject: object)))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertThrowsError(try ComponentInventoryDocumentCodec.decode(Data(("{\"kind\":\"airs.components\"," + text.dropFirst()).utf8)))
        var payload = try XCTUnwrap(object["inventory"] as? [String: Any])
        payload["components"] = Array(repeating: ["id":"invalid"], count: 129)
        object.removeValue(forKey: "sourceURL"); object["inventory"] = payload
        XCTAssertThrowsError(try ComponentInventoryDocumentCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testInvalidParentsAndPathsDoNotBecomeInventorySuccess() throws {
        let base = fixture()
        let invalid = ComponentInventory(scope: base.scope, components: [
            .init(parentID: UUID(), relativePath: "../escape", kind: "app", architectures: ["arm64"])])
        XCTAssertThrowsError(try ComponentInventoryDocumentCodec.encode(invalid))
    }
}
