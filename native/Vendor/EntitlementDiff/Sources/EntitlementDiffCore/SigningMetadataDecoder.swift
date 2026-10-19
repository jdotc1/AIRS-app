import Foundation

public enum SigningMetadataError: Error, Sendable, Equatable, LocalizedError {
    case unsigned
    case malformedIdentifier
    case identifierTooLarge
    case undecodedEntitlements

    public var errorDescription: String? {
        switch self {
        case .unsigned:
            "No signing identifier was returned (unsigned input). This is not an empty entitlement set."
        case .malformedIdentifier:
            "The extracted signing identifier is missing its expected nonempty string value."
        case .identifierTooLarge:
            "The extracted signing identifier exceeds the 4,096-byte UTF-8 limit."
        case .undecodedEntitlements:
            "An entitlement blob exists but the system did not provide a decoded dictionary. No comparison was produced."
        }
    }
}

public struct DecodedSigningMetadata: Sendable {
    public let signingIdentifier: String
    public let presence: EntitlementPresence
    public let entitlements: EntitlementDictionary
}

/// This separately testable boundary does not assume a successful native call
/// means signed, valid, or empty. It does not reinterpret an undecoded raw blob.
public struct SigningMetadataDecoder: Sendable {
    public static let maximumSigningIdentifierBytes = 4_096
    private let decoder: FoundationEntitlementDecoder
    public init(limits: DecodeLimits = .init()) { decoder = .init(limits: limits) }

    public func decode(signingIdentifier: Any?, entitlementDictionary: Any?,
                       hasRawEntitlements: Bool) throws -> DecodedSigningMetadata {
        guard let rawIdentifier = signingIdentifier else { throw SigningMetadataError.unsigned }
        guard let identifier = rawIdentifier as? String, !identifier.isEmpty else {
            throw SigningMetadataError.malformedIdentifier
        }
        guard identifier.utf8.count <= Self.maximumSigningIdentifierBytes else {
            throw SigningMetadataError.identifierTooLarge
        }
        if let dictionary = entitlementDictionary {
            return .init(signingIdentifier: identifier, presence: .dictionaryPresent,
                         entitlements: try decoder.decode(dictionary))
        }
        guard !hasRawEntitlements else { throw SigningMetadataError.undecodedEntitlements }
        return .init(signingIdentifier: identifier, presence: .notPresent, entitlements: .init())
    }
}
