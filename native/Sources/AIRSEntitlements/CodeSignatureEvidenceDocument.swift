import AIRSCore
import CryptoKit
import Foundation

/// Additive raw signature evidence; existing inspection/snapshot schemas are
/// unchanged. Import validates the retained SuperBlob and each byte range/hash.
/// Original container/slice digests remain historical identities, not proof that
/// an unavailable original still exists or that Apple trusts its signature.
public struct CodeSignatureEvidenceDocument: Sendable {
    public static let kind = "airs.signature-evidence"
    public static let maximumBytes = 16 * 1_048_576
    public let evidence: CodeSignatureEvidence
    public let capturedAt: Date
    public let producerVersion: String

    public init(evidence: CodeSignatureEvidence, capturedAt: Date, producerVersion: String) throws {
        self.evidence = evidence; self.capturedAt = capturedAt; self.producerVersion = producerVersion
        try validate()
    }

    public static func capture(unit: BundleImageProvenance, componentID: UUID,
                               producerVersion: String = "0.3.1") throws -> Self {
        try .init(evidence: CodeSignatureEvidenceReader().capture(unit: unit, componentID: componentID),
                  capturedAt: Date(), producerVersion: producerVersion)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw InspectionArchiveError.limit }
        try validateShape(BoundJSON.parse(data))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let wire = try decoder.decode(Wire.self, from: data)
        return try .init(evidence: wire.evidence, capturedAt: wire.capturedAt, producerVersion: wire.producerVersion)
    }

    public func data() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Wire(kind: Self.kind, schemaVersion: 1, capturedAt: capturedAt,
                                          producerVersion: producerVersion, evidence: evidence))
        guard bytes.count <= Self.maximumBytes else { throw InspectionArchiveError.limit }
        return bytes
    }

    public func archive() throws -> Data {
        let bytes = try data(), id = UUID()
        let item = EvidenceAttachment(id: id, kind: Self.kind, schemaVersion: 1, mediaType: "application/json",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: bytes.count, bytes: bytes)
        return try InspectionArchive(attachments: [item], components: [.init(id: evidence.componentID, evidenceIDs: [id])]).encode()
    }

    private func validate() throws {
        guard !producerVersion.isEmpty, producerVersion.utf8.count <= 256,
              !producerVersion.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              capturedAt.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(capturedAt.timeIntervalSince1970) else { throw InspectionArchiveError.invalid }
        try evidence.validate()
    }

    private struct Wire: Codable {
        let kind: String
        let schemaVersion: Int
        let capturedAt: Date
        let producerVersion: String
        let evidence: CodeSignatureEvidence
    }

    /// Exact key sets and unsigned integer tokens are checked before Foundation
    /// decoding. Unknown trust flags, bool/float coercions and oversized base64
    /// payloads cannot be silently ignored by synthesized Codable implementations.
    private static func validateShape(_ node: BoundJSONNode) throws {
        func object(_ node: BoundJSONNode?, required: Set<String>, optional: Set<String> = []) throws -> [String: BoundJSONNode] {
            guard let node else { throw InspectionArchiveError.invalid }
            let fields = try BoundJSON.object(node), keys = Set(fields.keys)
            guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else { throw InspectionArchiveError.invalid }
            return fields
        }
        func integer(_ node: BoundJSONNode?, maximum: UInt64 = UInt64.max) throws {
            guard try BoundJSON.integer(node) <= maximum else { throw InspectionArchiveError.invalid }
        }
        func array(_ node: BoundJSONNode?, maximum: Int) throws -> [BoundJSONNode] {
            guard case .array(let values) = node, values.count <= maximum else { throw InspectionArchiveError.limit }
            return values
        }
        func rawBytes(_ node: BoundJSONNode?) throws -> Int {
            let text = try BoundJSON.text(node, max: ((512 * 1_024 + 2) / 3) * 4)
            guard let bytes = Data(base64Encoded: text), bytes.count <= 512 * 1_024,
                  bytes.base64EncodedString() == text else { throw InspectionArchiveError.invalid }
            return bytes.count
        }
        let top = try object(node, required: ["kind", "schemaVersion", "capturedAt", "producerVersion", "evidence"])
        guard try BoundJSON.text(top["kind"]) == kind else { throw InspectionArchiveError.invalid }
        guard try BoundJSON.integer(top["schemaVersion"]) == 1 else { throw InspectionArchiveError.unsupportedVersion }
        _ = try BoundJSON.text(top["capturedAt"], max: 64)
        _ = try BoundJSON.text(top["producerVersion"])
        let evidence = try object(top["evidence"], required: ["componentID", "componentRelativePath", "containerSHA256",
            "containerByteCount", "bytesHashed", "headerBytesRead", "signatureBytesRead", "limits", "slices"])
        _ = try BoundJSON.uuid(evidence["componentID"])
        _ = try BoundJSON.text(evidence["componentRelativePath"], max: 4096)
        _ = try BoundJSON.digest(evidence["containerSHA256"])
        for name in ["containerByteCount", "bytesHashed", "headerBytesRead", "signatureBytesRead"] { try integer(evidence[name]) }
        let limits = try object(evidence["limits"], required: ["maximumContainerBytes", "maximumHeaderBytes",
            "maximumSignatureBytes", "maximumTotalSignatureBytes", "maximumSlotCount"])
        for value in limits.values { try integer(value) }
        var signatureTotal = 0, entitlementTotal = 0
        for item in try array(evidence["slices"], maximum: 64) {
            let slice = try object(item, required: ["index", "cpuType", "cpuSubtype", "headerMagic", "sliceOffset", "sliceSize",
                "sliceSHA256", "loadCommandsEnd", "state", "slots"], optional: ["problem", "signatureOffset", "signatureByteCount", "signatureSHA256", "signatureBytes"])
            for name in ["index", "sliceOffset", "sliceSize", "loadCommandsEnd"] { try integer(slice[name]) }
            for name in ["cpuType", "cpuSubtype", "headerMagic"] { try integer(slice[name], maximum: UInt64(UInt32.max)) }
            for name in ["signatureOffset", "signatureByteCount"] { if let value = slice[name] { try integer(value) } }
            _ = try BoundJSON.digest(slice["sliceSHA256"])
            if let value = slice["signatureSHA256"] { _ = try BoundJSON.digest(value) }
            guard CodeSignatureEvidenceState(rawValue: try BoundJSON.text(slice["state"])) != nil else { throw InspectionArchiveError.invalid }
            if let value = slice["problem"] {
                guard CodeSignatureEvidenceProblem(rawValue: try BoundJSON.text(value)) != nil else { throw InspectionArchiveError.invalid }
            }
            if let value = slice["signatureBytes"] {
                let count = try rawBytes(value)
                guard count <= 4 * 1_048_576 - signatureTotal else { throw InspectionArchiveError.limit }
                signatureTotal += count
            }
            for item in try array(slice["slots"], maximum: 2) {
                let slot = try object(item, required: ["type", "magic", "containerOffset", "sliceRelativeOffset", "byteCount", "sha256", "bytes"])
                for name in ["type", "magic"] { try integer(slot[name], maximum: UInt64(UInt32.max)) }
                for name in ["containerOffset", "sliceRelativeOffset", "byteCount"] { try integer(slot[name]) }
                _ = try BoundJSON.digest(slot["sha256"])
                let count = try rawBytes(slot["bytes"])
                guard count <= 4 * 1_048_576 - entitlementTotal else { throw InspectionArchiveError.limit }
                entitlementTotal += count
            }
        }
    }
}
