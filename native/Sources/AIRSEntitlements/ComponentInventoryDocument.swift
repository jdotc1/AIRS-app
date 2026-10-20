import Foundation
import CryptoKit
import AIRSCore
import EntitlementDiffCore

/// Portable declarations only. Live file provenance is never reconstructed from
/// an imported inventory, and source URLs are absent from this wire format.
public enum ComponentInventoryDocumentCodec {
    public static let kind = "airs.components"
    public static let maximumBytes = 8 * 1_048_576
    public static func decode(_ data: Data) throws -> ComponentInventory {
        guard data.count <= maximumBytes else { throw InspectionArchiveError.limit }
        try EvidenceEnvelopeJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["kind", "schemaVersion", "inventory"], object["kind"] as? String == kind else { throw InspectionArchiveError.invalid }
        guard object["schemaVersion"] as? Int == 1 else { throw InspectionArchiveError.unsupportedVersion }
        guard let inventory = object["inventory"] as? [String: Any], Set(inventory.keys) == ["id", "capturedAt", "scope", "components"],
              let records = inventory["components"] as? [[String: Any]], records.count <= 128,
              let scope = inventory["scope"] as? [String: Any], Set(scope.keys) == ["searchedLocations", "completion", "exclusions", "issues"] else { throw InspectionArchiveError.invalid }
        for key in ["searchedLocations", "exclusions", "issues"] {
            guard let values = scope[key] as? [String], values.count <= (key == "searchedLocations" ? 16 : 256),
                  values.allSatisfy({ $0.utf8.count <= 4096 }) else { throw InspectionArchiveError.limit }
        }
        let allowed: Set<String> = ["id", "parentID", "relativePath", "kind", "declaredBundleID", "declaredVersion", "architectures", "minimumOSByArchitecture", "readIssues"]
        for record in records {
            guard Set(record.keys).isSubset(of: allowed),
                  let architectures = record["architectures"] as? [String], architectures.count <= 64,
                  let issues = record["readIssues"] as? [String], issues.count <= 64,
                  let minima = record["minimumOSByArchitecture"] as? [String: String], minima.count <= 64 else { throw InspectionArchiveError.limit }
        }
        return try JSONDecoder().decode(Wire.self, from: data).inventory
    }
    public static func encode(_ inventory: ComponentInventory) throws -> Data {
        try inventory.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Wire(kind: kind, schemaVersion: 1, inventory: inventory))
        guard bytes.count <= maximumBytes else { throw InspectionArchiveError.limit }
        return bytes
    }
    public static func archive(_ inventory: ComponentInventory) throws -> Data {
        try archive(payload: encode(inventory))
    }
    public static func archive(payload: Data) throws -> Data {
        let inventory = try decode(payload), attachmentID = UUID()
        let attachment = EvidenceAttachment(id: attachmentID, kind: kind, schemaVersion: 1, mediaType: "application/json",
            sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(), byteCount: payload.count, bytes: payload)
        return try InspectionArchive(attachments: [attachment], components: inventory.components.map {
            .init(id: $0.id, evidenceIDs: [attachmentID])
        }).encode()
    }
    private struct Wire: Codable {
        let kind: String
        let schemaVersion: Int
        let inventory: ComponentInventory
    }
}
