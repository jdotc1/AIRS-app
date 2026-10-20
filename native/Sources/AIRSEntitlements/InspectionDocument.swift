import Foundation
import EntitlementDiffCore

public enum InspectionDocumentError: Error, LocalizedError, Sendable {
    case invalid, limit

    public var errorDescription: String? {
        switch self {
        case .invalid: "Not a supported, valid AIRS schema-1 inspection document."
        case .limit: "Inspection document exceeds import limits (8 MiB, 96 JSON levels, 100,000 nodes or 1 MiB per string)."
        }
    }
}

/// The source when a document was created. In an imported document this is an
/// author's recorded claim; snapshot.isSavedBaseline describes this session.
public enum InspectionCaptureProvenance: String, Codable, Sendable {
    case nativeExtraction, savedSnapshot, syntheticExample
}

/// Captured Info.plist labels, not authenticated signing or application identity.
/// Values retain exact Unicode spelling; slash characters are legitimate content.
public struct InspectionIdentity: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let version: String?
    public let build: String?

    public init(bundleIdentifier: String? = nil, version: String? = nil, build: String? = nil) throws {
        for field in [bundleIdentifier, version, build].compactMap({ $0 }) {
            guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.utf8.count <= AppIdentity.maximumFieldBytes,
                  !field.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw InspectionDocumentError.invalid
            }
        }
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
    }

    fileprivate var appIdentity: AppIdentity {
        var fields: [String: Any] = [:]
        if let bundleIdentifier { fields["CFBundleIdentifier"] = bundleIdentifier }
        if let version { fields["CFBundleShortVersionString"] = version }
        if let build { fields["CFBundleVersion"] = build }
        return AppIdentity(infoPlist: fields)
    }
}

/// One captured entitlement extraction. No original executable, source URL,
/// binary hash, signature validation or atomic-filesystem claim is retained.
public struct InspectionDocument: Sendable {
    public static let kind = "airs.inspection"
    public static let schemaVersion = 1
    public static let scope = "mainExecutableRequestedArchitecture"
    public let snapshot: EntitlementSnapshot
    public let capturedAt: Date
    public let producerVersion: String
    public let identity: InspectionIdentity?
    public let captureProvenance: InspectionCaptureProvenance
    public let originalBinaryRetained = false

    public init(snapshot: EntitlementSnapshot, capturedAt: Date, producerVersion: String) throws {
        try validateHeader(date: capturedAt.timeIntervalSince1970, producer: producerVersion)
        do { _ = try EntitlementSnapshotJSONCodec.encode(snapshot) }
        catch { throw documentError(error) }
        self.snapshot = snapshot
        // Normalize to the timestamp precision carried by the wire representation.
        self.capturedAt = Date(timeIntervalSince1970: capturedAt.timeIntervalSince1970)
        self.producerVersion = producerVersion
        identity = try snapshot.identity.map {
            try InspectionIdentity(bundleIdentifier: $0.bundleIdentifier, version: $0.version, build: $0.build)
        }
        captureProvenance = snapshot.origin == .syntheticExample ? .syntheticExample
            : (snapshot.isSavedBaseline ? .savedSnapshot : .nativeExtraction)
    }

    fileprivate init(snapshot: EntitlementSnapshot, metadata: InspectionMetadata) throws {
        guard (snapshot.origin == .syntheticExample) == (metadata.provenance == .syntheticExample) else {
            throw InspectionDocumentError.invalid
        }
        identity = metadata.identity
        self.snapshot = EntitlementSnapshot(sourceName: snapshot.sourceName,
            signingIdentifier: snapshot.signingIdentifier, architecture: snapshot.architecture,
            presence: snapshot.presence, origin: snapshot.origin, entitlements: snapshot.entitlements,
            identity: metadata.identity?.appIdentity, isSavedBaseline: true)
        capturedAt = Date(timeIntervalSince1970: metadata.timestamp)
        producerVersion = metadata.producer
        captureProvenance = metadata.provenance
    }
}

public enum InspectionDocumentCodec {
    public static let maximumBytes = EntitlementSnapshotJSONCodec.maximumBytes

    public static func decode(_ data: Data) throws -> InspectionDocument {
        do {
            let snapshot = try EntitlementSnapshotJSONCodec.decodeEnvelope(data, snapshotKey: "snapshot",
                expectedKeys: Set(InspectionField.allCases.map(\.rawValue)),
                schemaVersion: InspectionDocument.schemaVersion)
            // Only decode descriptive fields after the complete JSON has passed
            // duplicate-key, token, depth, node and byte validation.
            let metadata = try JSONDecoder().decode(InspectionMetadata.self, from: data)
            return try InspectionDocument(snapshot: snapshot, metadata: metadata)
        } catch { throw documentError(error) }
    }

    public static func encode(_ document: InspectionDocument) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var bytes = try encoder.encode(InspectionWire(document: document))
            bytes.append(0x0A)
            _ = try decode(bytes)
            return bytes
        } catch { throw documentError(error) }
    }

    /// Bounded local-file ingestion. Callers own security-scoped access and UI work.
    public static func read(at url: URL) throws -> InspectionDocument {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw InspectionDocumentError.invalid
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InspectionDocumentError.invalid
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        // A regular-file read may still be short; read through EOF or the limit.
        while bytes.count <= maximumBytes {
            let remaining = maximumBytes + 1 - bytes.count
            let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        return try decode(bytes)
    }
}

private enum InspectionField: String, CodingKey, CaseIterable {
    case kind, schemaVersion, scope, signatureValidation, gatekeeperAssessment
    case capturedAtUnixSeconds, producerVersion, captureProvenance, originalBinaryRetained
    case identity, snapshot
}

private struct InspectionWire: Encodable {
    let document: InspectionDocument
    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: InspectionField.self)
        try fields.encode(InspectionDocument.kind, forKey: .kind)
        try fields.encode(InspectionDocument.schemaVersion, forKey: .schemaVersion)
        try fields.encode(InspectionDocument.scope, forKey: .scope)
        try fields.encode("notPerformed", forKey: .signatureValidation)
        try fields.encode("notPerformed", forKey: .gatekeeperAssessment)
        try fields.encode(document.capturedAt.timeIntervalSince1970, forKey: .capturedAtUnixSeconds)
        try fields.encode(document.producerVersion, forKey: .producerVersion)
        try fields.encode(document.captureProvenance, forKey: .captureProvenance)
        try fields.encode(false, forKey: .originalBinaryRetained)
        try fields.encode(document.identity.map(IdentityWire.init), forKey: .identity)
        try fields.encode(document.snapshot, forKey: .snapshot)
    }
}

fileprivate struct InspectionMetadata: Decodable {
    let timestamp: Double
    let producer: String
    let provenance: InspectionCaptureProvenance
    let identity: InspectionIdentity?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: InspectionField.self)
        guard try fields.decode(String.self, forKey: .kind) == InspectionDocument.kind,
              try fields.decode(Int.self, forKey: .schemaVersion) == InspectionDocument.schemaVersion,
              try fields.decode(String.self, forKey: .scope) == InspectionDocument.scope,
              try fields.decode(String.self, forKey: .signatureValidation) == "notPerformed",
              try fields.decode(String.self, forKey: .gatekeeperAssessment) == "notPerformed",
              try fields.decode(Bool.self, forKey: .originalBinaryRetained) == false else {
            throw InspectionDocumentError.invalid
        }
        timestamp = try fields.decode(Double.self, forKey: .capturedAtUnixSeconds)
        producer = try fields.decode(String.self, forKey: .producerVersion)
        try validateHeader(date: timestamp, producer: producer)
        provenance = try fields.decode(InspectionCaptureProvenance.self, forKey: .captureProvenance)
        identity = try fields.decode(IdentityWire?.self, forKey: .identity)?.value
    }
}

private struct IdentityWire: Codable {
    let value: InspectionIdentity
    init(_ value: InspectionIdentity) { self.value = value }
    enum Key: String, CodingKey, CaseIterable { case bundleIdentifier, version, build }

    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AnyInspectionKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(Key.allCases.map(\.rawValue)) else {
            throw InspectionDocumentError.invalid
        }
        let fields = try decoder.container(keyedBy: Key.self)
        value = try InspectionIdentity(
            bundleIdentifier: fields.decode(String?.self, forKey: .bundleIdentifier),
            version: fields.decode(String?.self, forKey: .version),
            build: fields.decode(String?.self, forKey: .build))
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(value.bundleIdentifier, forKey: .bundleIdentifier)
        try fields.encode(value.version, forKey: .version)
        try fields.encode(value.build, forKey: .build)
    }
}

private struct AnyInspectionKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func validateHeader(date: Double, producer: String) throws {
    // This document records captures from 2001 through 9999, in UTC Unix seconds.
    guard date.isFinite, date >= 978_307_200, date < 253_402_300_800,
          producer.utf8.count <= 64,
          producer.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
              || (97...122).contains($0) || [43, 45, 46].contains($0) }),
          producer.range(of: #"^[0-9]+(?:\.[0-9]+){0,3}(?:[-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$"#,
                         options: .regularExpression) != nil else {
        throw InspectionDocumentError.invalid
    }
}

private func documentError(_ error: Error) -> InspectionDocumentError {
    if let document = error as? InspectionDocumentError { return document }
    if let saved = error as? SavedReportError, case .limit = saved { return .limit }
    return .invalid
}
