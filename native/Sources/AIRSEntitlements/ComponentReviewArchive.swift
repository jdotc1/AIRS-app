import Foundation
import CryptoKit
import AIRSCore
import EntitlementDiffCore

public enum ComponentReviewArchive {
    public static let kind = "airs.component.review"
    private struct Outcome: Codable {
        let matchID: UUID
        let architecture: String
        let attachmentID: UUID?
        let reason: String?
    }
    private struct Manifest: Codable {
        let kind: String
        let schemaVersion: Int
        let previousID: UUID
        let currentID: UUID
        let architecture: String
        let previousDeclarations: [DeclarationObservation]
        let currentDeclarations: [DeclarationObservation]
        let outcomes: [Outcome]
    }
    private static func manifest(_ data: Data) throws -> Manifest {
        guard data.count <= 16 * 1_048_576 else { throw InspectionArchiveError.limit }
        try EvidenceEnvelopeJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              Set(object.keys) == ["kind","schemaVersion","previousID","currentID","architecture","previousDeclarations","currentDeclarations","outcomes"],
              object["kind"] as? String == kind else { throw InspectionArchiveError.invalid }
        guard object["schemaVersion"] as? Int == 1 else { throw InspectionArchiveError.unsupportedVersion }
        for key in ["previousDeclarations", "currentDeclarations", "outcomes"] {
            guard let rows = object[key] as? [[String:Any]], rows.count <= (key == "outcomes" ? 256 : 384) else { throw InspectionArchiveError.limit }
            let allowed: Set<String> = key == "outcomes" ? ["matchID","architecture","attachmentID","reason"] : ["componentID","category","architecture","relativeSource","state","bytes","issue"]
            guard rows.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw InspectionArchiveError.invalid }
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }
    public static func validateManifest(_ data: Data) throws { _ = try manifest(data) }
    private static func attachment(_ kind: String, _ bytes: Data, id: UUID = UUID()) -> EvidenceAttachment {
        .init(id: id, kind: kind, schemaVersion: 1, mediaType: "application/json",
              sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: bytes.count, bytes: bytes)
    }
    public static func encode(_ review: ComponentReview) throws -> Data {
        let valid = try ComponentComparison.review(previous: review.previous, current: review.current, architecture: review.architecture,
            entitlementResults: review.entitlementResults, previousDeclarations: review.previousDeclarations, currentDeclarations: review.currentDeclarations)
        guard valid.previous.components.count + valid.current.components.count <= 128 else { throw InspectionArchiveError.limit }
        let a = attachment(ComponentInventoryDocumentCodec.kind, try ComponentInventoryDocumentCodec.encode(valid.previous))
        let b = attachment(ComponentInventoryDocumentCodec.kind, try ComponentInventoryDocumentCodec.encode(valid.current))
        var attachments = [a,b], outcomes: [Outcome] = []
        for result in valid.entitlementResults {
            switch result {
            case .compared(let id, let architecture, let report):
                let item = attachment("EntitlementDiff", try report.jsonData()); attachments.append(item)
                outcomes.append(.init(matchID: id, architecture: architecture.rawValue, attachmentID: item.id, reason: nil))
            case .unavailable(let id, let architecture, let reason): outcomes.append(.init(matchID: id, architecture: architecture.rawValue, attachmentID: nil, reason: reason))
            }
        }
        let value = Manifest(kind: kind, schemaVersion: 1, previousID: a.id, currentID: b.id, architecture: valid.architecture.rawValue,
            previousDeclarations: valid.previousDeclarations, currentDeclarations: valid.currentDeclarations, outcomes: outcomes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        attachments.append(attachment(kind, try encoder.encode(value)))
        // Per-inventory UUID membership lives in its bound payload, not a union
        // that would silently widen the archive's 128 top-level reference budget.
        return try InspectionArchive(attachments: attachments).encode()
    }
    public static func decode(_ archive: InspectionArchive) throws -> ComponentReview {
        let manifests = archive.attachments.filter { $0.kind == kind && $0.schemaVersion == 1 && $0.mediaType == "application/json" }
        guard manifests.count == 1, let item = manifests.first else { throw InspectionArchiveError.invalid }
        let value = try manifest(item.bytes)
        func inventory(_ id: UUID) throws -> ComponentInventory {
            guard let record = archive.attachments.first(where: { $0.id == id }), record.kind == ComponentInventoryDocumentCodec.kind,
                  record.schemaVersion == 1, record.mediaType == "application/json" else { throw InspectionArchiveError.invalid }
            return try ComponentInventoryDocumentCodec.decode(record.bytes)
        }
        let a = try inventory(value.previousID), b = try inventory(value.currentID)
        guard a.components.count + b.components.count <= 128,
              let architecture = Architecture(rawValue: value.architecture) else { throw InspectionArchiveError.limit }
        guard value.previousID != value.currentID else { throw InspectionArchiveError.invalid }
        var used = Set<UUID>(), results: [ComponentEntitlementResult] = []
        for outcome in value.outcomes {
            guard let requested = Architecture(rawValue: outcome.architecture) else { throw InspectionArchiveError.invalid }
            if let id = outcome.attachmentID {
                guard outcome.reason == nil, used.insert(id).inserted,
                      let payload = archive.attachments.first(where: { $0.id == id }), payload.kind == "EntitlementDiff",
                      payload.schemaVersion == 1, payload.mediaType == "application/json" else { throw InspectionArchiveError.invalid }
                let saved = try SavedReport.parse(payload.bytes)
                results.append(.compared(matchID: outcome.matchID, architecture: requested,
                    report: try .init(previous: saved.previous, current: saved.current)))
            } else {
                guard let reason = outcome.reason else { throw InspectionArchiveError.invalid }
                results.append(.unavailable(matchID: outcome.matchID, architecture: requested, reason: reason))
            }
        }
        return try ComponentComparison.review(previous: a, current: b, architecture: architecture,
            entitlementResults: results, previousDeclarations: value.previousDeclarations, currentDeclarations: value.currentDeclarations)
    }
}
