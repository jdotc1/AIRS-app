import Foundation
import CryptoKit
import AIRSCore
import EntitlementDiffCore

public enum InspectionArchiveError: Error, LocalizedError, Equatable, Sendable {
    case invalid, limit, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalid: "Invalid AIRS review archive or attachment identity."
        case .limit: "AIRS review archive exceeds its file, record or attachment limits."
        case .unsupportedVersion: "Unsupported AIRS review archive version."
        }
    }
}

/// All payload validation is recomputed in this process; imported trust flags
/// are not part of the format. Exact payload bytes are never regenerated.
public struct InspectionArchive: Sendable {
    public static let kind = "airs.review"
    public static let maximumBytes = 32 * 1_024 * 1_024
    public let attachments: [EvidenceAttachment]
    public let components: [ArchiveComponentReference]

    public init(attachments: [EvidenceAttachment], components: [ArchiveComponentReference] = []) {
        self.attachments = attachments; self.components = components
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw InspectionArchiveError.limit }
        // The shared parser enforces duplicate-key, depth, node and string budgets
        // before Foundation decodes the bounded manifest and base64 chunks.
        try EvidenceEnvelopeJSON.validate(data)
        let wire = try JSONDecoder().decode(ArchiveWire.self, from: data)
        guard wire.kind == kind else { throw InspectionArchiveError.invalid }
        guard wire.schemaVersion == 1 else { throw InspectionArchiveError.unsupportedVersion }
        let result = Self(attachments: try wire.attachments.map { try $0.attachment() }, components: wire.components)
        try result.validate()
        return result
    }

    public func encode() throws -> Data {
        try validate()
        let wire = ArchiveWire(kind: Self.kind, schemaVersion: 1,
            attachments: attachments.map(AttachmentWire.init), components: components)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= Self.maximumBytes else { throw InspectionArchiveError.limit }
        return data
    }

    public func validation(for id: UUID) throws -> EvidenceValidation {
        guard let item = attachments.first(where: { $0.id == id }) else { throw InspectionArchiveError.invalid }
        try validateIdentity(item)
        guard item.schemaVersion == 1, item.mediaType == "application/json" else { return .uninterpreted }
        switch item.kind {
        case AssessmentDocument.kind: _ = try AssessmentDocument.decode(item.bytes)
        case InspectionDocument.kind: _ = try InspectionDocumentCodec.decode(item.bytes)
        case CodeSignatureEvidenceDocument.kind: _ = try CodeSignatureEvidenceDocument.decode(item.bytes)
        case "EntitlementDiff": _ = try SavedReport.parse(item.bytes)
        case "airs.audit": _ = try AuditReport.decode(item.bytes)
        case ComponentInventoryDocumentCodec.kind: _ = try ComponentInventoryDocumentCodec.decode(item.bytes)
        case ComponentReviewArchive.kind: try ComponentReviewArchive.validateManifest(item.bytes)
        default: return .uninterpreted
        }
        return .supported
    }

    private func validate() throws {
        guard attachments.count <= 256, components.count <= 128 else { throw InspectionArchiveError.limit }
        let ids = Set(attachments.map(\.id))
        guard ids.count == attachments.count, Set(components.map(\.id)).count == components.count else { throw InspectionArchiveError.invalid }
        for component in components {
            guard component.evidenceIDs.count <= 256,
                  Set(component.evidenceIDs).count == component.evidenceIDs.count,
                  component.evidenceIDs.allSatisfy(ids.contains) else { throw InspectionArchiveError.invalid }
        }
        var total = 0
        for attachment in attachments {
            guard attachment.bytes.count <= Self.maximumBytes - total else { throw InspectionArchiveError.limit }
            total += attachment.bytes.count
            _ = try validation(for: attachment.id)
        }
        if attachments.contains(where: { $0.kind == ComponentReviewArchive.kind && $0.schemaVersion == 1 && $0.mediaType == "application/json" }) {
            _ = try ComponentReviewArchive.decode(self)
        }
        // Base64 expansion is included in the complete-file budget before encoding.
        let encodedPayload = attachments.reduce(0) { $0 + (($1.bytes.count + 2) / 3) * 4 }
        guard encodedPayload <= Self.maximumBytes else { throw InspectionArchiveError.limit }
    }

    private func validateIdentity(_ item: EvidenceAttachment) throws {
        guard item.byteCount == item.bytes.count, item.byteCount >= 0,
              item.schemaVersion > 0, item.kind.utf8.count <= 256, !item.kind.isEmpty,
              item.mediaType.utf8.count <= 256, !item.mediaType.isEmpty,
              item.sha256.utf8.count == 64,
              item.sha256 == SHA256.hash(data: item.bytes).map({ String(format: "%02x", $0) }).joined()
        else { throw InspectionArchiveError.invalid }
    }
}

private struct ArchiveWire: Codable {
    let kind: String
    let schemaVersion: Int
    let attachments: [AttachmentWire]
    let components: [ArchiveComponentReference]
    enum Key: String, CodingKey { case kind, schemaVersion, attachments, components }
    init(kind: String, schemaVersion: Int, attachments: [AttachmentWire], components: [ArchiveComponentReference]) {
        self.kind = kind; self.schemaVersion = schemaVersion; self.attachments = attachments; self.components = components
    }
    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["kind", "schemaVersion", "attachments", "components"])
        let c = try decoder.container(keyedBy: Key.self)
        kind = try c.decode(String.self, forKey: .kind)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard kind == InspectionArchive.kind else { throw InspectionArchiveError.invalid }
        guard schemaVersion == 1 else { throw InspectionArchiveError.unsupportedVersion }
        var items = try c.nestedUnkeyedContainer(forKey: .attachments)
        guard (items.count ?? 257) <= 256 else { throw InspectionArchiveError.limit }
        var decoded: [AttachmentWire] = []
        while !items.isAtEnd { decoded.append(try items.decode(AttachmentWire.self)) }
        attachments = decoded
        var records = try c.nestedUnkeyedContainer(forKey: .components)
        guard (records.count ?? 129) <= 128 else { throw InspectionArchiveError.limit }
        var references: [ArchiveComponentReference] = []
        while !records.isAtEnd {
            let decoder = try records.superDecoder()
            try rejectUnknownKeys(decoder, allowed: ["id", "evidenceIDs"])
            references.append(try ComponentReferenceWire(from: decoder).reference)
        }
        components = references
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind); try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(attachments, forKey: .attachments); try c.encode(components, forKey: .components)
    }
}

private struct ComponentReferenceWire: Decodable {
    let reference: ArchiveComponentReference
    enum Key: String, CodingKey { case id, evidenceIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let id = try c.decode(UUID.self, forKey: .id)
        var values = try c.nestedUnkeyedContainer(forKey: .evidenceIDs)
        guard (values.count ?? 257) <= 256 else { throw InspectionArchiveError.limit }
        var ids: [UUID] = []
        while !values.isAtEnd { ids.append(try values.decode(UUID.self)) }
        reference = .init(id: id, evidenceIDs: ids)
    }
}

private struct AttachmentWire: Codable {
    let id: UUID
    let kind: String
    let schemaVersion: Int
    let mediaType: String
    let sha256: String
    let byteCount: Int
    let chunks: [Data]
    static let chunkBytes = 512 * 1_024
    init(_ item: EvidenceAttachment) {
        id = item.id; kind = item.kind; schemaVersion = item.schemaVersion
        mediaType = item.mediaType; sha256 = item.sha256; byteCount = item.byteCount
        chunks = stride(from: 0, to: item.bytes.count, by: Self.chunkBytes).map {
            item.bytes.subdata(in: $0..<min($0 + Self.chunkBytes, item.bytes.count))
        }
    }
    enum Key: String, CodingKey { case id, kind, schemaVersion, mediaType, sha256, byteCount, chunks }
    init(from decoder: Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["id", "kind", "schemaVersion", "mediaType", "sha256", "byteCount", "chunks"])
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        sha256 = try c.decode(String.self, forKey: .sha256)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        guard byteCount >= 0, byteCount <= InspectionArchive.maximumBytes else { throw InspectionArchiveError.limit }
        var encoded = try c.nestedUnkeyedContainer(forKey: .chunks)
        guard (encoded.count ?? 65) <= 64 else { throw InspectionArchiveError.limit }
        var decoded: [Data] = [], total = 0
        while !encoded.isAtEnd {
            let text = try encoded.decode(String.self)
            guard text.utf8.count <= ((Self.chunkBytes + 2) / 3) * 4,
                  let chunk = Data(base64Encoded: text), chunk.count <= Self.chunkBytes,
                  !chunk.isEmpty, chunk.count <= byteCount - total else { throw InspectionArchiveError.invalid }
            total += chunk.count; decoded.append(chunk)
        }
        guard total == byteCount else { throw InspectionArchiveError.invalid }
        chunks = decoded
    }
    func attachment() throws -> EvidenceAttachment {
        var bytes = Data(); bytes.reserveCapacity(byteCount)
        for chunk in chunks { bytes.append(chunk) }
        return .init(id: id, kind: kind, schemaVersion: schemaVersion, mediaType: mediaType,
                     sha256: sha256, byteCount: byteCount, bytes: bytes)
    }
}

private struct AnyArchiveKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func rejectUnknownKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let c = try decoder.container(keyedBy: AnyArchiveKey.self)
    guard c.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw InspectionArchiveError.invalid }
}
