import Foundation

/// Byte identity of retained evidence, never identity of an inspected executable.
public struct EvidenceAttachment: Codable, Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let schemaVersion: Int
    public let mediaType: String
    public let sha256: String
    public let byteCount: Int
    public let bytes: Data

    public init(id: UUID, kind: String, schemaVersion: Int, mediaType: String,
                sha256: String, byteCount: Int, bytes: Data) {
        self.id = id; self.kind = kind; self.schemaVersion = schemaVersion
        self.mediaType = mediaType; self.sha256 = sha256
        self.byteCount = byteCount; self.bytes = bytes
    }
}

public enum EvidenceValidation: String, Codable, Sendable {
    case supported, uninterpreted
}

/// Manifest-local relationship only; no filename or bundle identifier matching.
public struct ArchiveComponentReference: Codable, Sendable, Identifiable {
    public let id: UUID
    public let evidenceIDs: [UUID]
    public init(id: UUID, evidenceIDs: [UUID]) { self.id = id; self.evidenceIDs = evidenceIDs }
}
