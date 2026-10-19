import Foundation

public enum Architecture: String, Sendable, CaseIterable, Encodable {
    case arm64, x86_64
    public static var hostDefault: Self {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }
}

public enum EntitlementPresence: String, Sendable, Encodable {
    case dictionaryPresent
    case notPresent
}

public enum SnapshotOrigin: String, Sendable, Encodable {
    case extracted
    case syntheticExample
}

/// A captured API result, not a validated code signature or effective permission set.
public struct EntitlementSnapshot: Sendable, Encodable {
    public let sourceName: String
    public let signingIdentifier: String
    public let architecture: Architecture
    public let presence: EntitlementPresence
    public let origin: SnapshotOrigin
    public let entitlements: EntitlementDictionary
    public let identity: AppIdentity?
    /// Session provenance; excluded from schema-1 snapshot fields.
    public let isSavedBaseline: Bool

    // UI-only metadata must never change the report schema or expose local source state.
    private enum CodingKeys: String, CodingKey {
        case sourceName, signingIdentifier, architecture, presence, origin, entitlements
    }

    public init(sourceName: String, signingIdentifier: String, architecture: Architecture,
                presence: EntitlementPresence = .dictionaryPresent,
                origin: SnapshotOrigin = .extracted, entitlements: EntitlementDictionary, identity: AppIdentity? = nil, isSavedBaseline: Bool = false) {
        self.sourceName = sourceName
        self.signingIdentifier = signingIdentifier
        self.architecture = architecture
        self.presence = presence
        self.origin = origin
        self.entitlements = entitlements
        self.identity = identity
        self.isSavedBaseline = isSavedBaseline
    }
}

public protocol SnapshotReading: Sendable {
    func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot
}
