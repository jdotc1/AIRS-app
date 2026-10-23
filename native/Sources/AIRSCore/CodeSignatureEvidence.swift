import CryptoKit
import Foundation

/// Byte evidence only. None of these states is a cryptographic, trust, policy,
/// notarization, entitlement-value or unwind verdict.
public enum CodeSignatureEvidenceState: String, Codable, Sendable {
    case collected, signatureAbsent, entitlementsAbsent, unexamined, malformed, budgetExceeded
}

public enum CodeSignatureEvidenceProblem: String, Codable, Sendable {
    case unsupportedArchitecture, duplicateCommand, invalidSignatureRange
    case invalidSuperBlob, signatureBudget, slotBudget
}

public enum CodeSignatureEvidenceError: Error, LocalizedError, Equatable, Sendable {
    case invalid, budgetExceeded, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalid: "Invalid or inconsistent raw signature evidence."
        case .budgetExceeded: "Raw signature capture exceeds its bounded container or metadata read budget."
        case .unavailable: "The discovered image is no longer available for an exact descriptor-bound read."
        }
    }
}

/// Limits are recorded in each capture and may only be lowered by callers.
/// Container hashing streams 64 KiB chunks once; signature retention and header
/// reads have independent budgets. Retained entitlement blobs duplicate at most
/// the retained signature bytes, so complete raw retention is at most 8 MiB.
public struct CodeSignatureEvidenceLimits: Codable, Equatable, Sendable {
    public let maximumContainerBytes: UInt64
    public let maximumHeaderBytes: Int
    public let maximumSignatureBytes: Int
    public let maximumTotalSignatureBytes: Int
    public let maximumSlotCount: Int

    public init(maximumContainerBytes: UInt64 = 512 * 1_048_576,
                maximumHeaderBytes: Int = 1_048_576,
                maximumSignatureBytes: Int = 512 * 1_024,
                maximumTotalSignatureBytes: Int = 4 * 1_048_576,
                maximumSlotCount: Int = 4096) {
        self.maximumContainerBytes = maximumContainerBytes; self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumSignatureBytes = maximumSignatureBytes; self.maximumTotalSignatureBytes = maximumTotalSignatureBytes
        self.maximumSlotCount = maximumSlotCount
    }

    func validate() throws {
        guard maximumContainerBytes > 0, maximumContainerBytes <= 512 * 1_048_576,
              maximumHeaderBytes > 0, maximumHeaderBytes <= 1_048_576,
              maximumSignatureBytes > 0, maximumSignatureBytes <= 512 * 1_024,
              maximumTotalSignatureBytes > 0, maximumTotalSignatureBytes <= 4 * 1_048_576,
              maximumSlotCount > 0, maximumSlotCount <= 4096 else { throw CodeSignatureEvidenceError.invalid }
    }
}

public struct CodeSignatureEntitlementBlob: Codable, Equatable, Sendable {
    public let type: UInt32
    public let magic: UInt32
    public let containerOffset: UInt64
    public let sliceRelativeOffset: UInt64
    public let byteCount: UInt64
    public let sha256: String
    /// Complete blob, including its eight-byte big-endian magic/length header.
    public let bytes: Data
}

public struct CodeSignatureSliceEvidence: Codable, Equatable, Sendable {
    public let index: Int
    public let cpuType: UInt32
    /// Preserves the capability bits; never joined by an architecture label.
    public let cpuSubtype: UInt32
    public let headerMagic: UInt32
    public let sliceOffset: UInt64
    public let sliceSize: UInt64
    public let sliceSHA256: String
    /// First container offset after the complete header/load-command region.
    public let loadCommandsEnd: UInt64
    public let state: CodeSignatureEvidenceState
    public let problem: CodeSignatureEvidenceProblem?
    /// Container-relative offset, not a VM address or a slice-relative offset.
    public let signatureOffset: UInt64?
    public let signatureByteCount: UInt64?
    public let signatureSHA256: String?
    /// Complete bounded LC_CODE_SIGNATURE region, including any trailing padding.
    public let signatureBytes: Data?
    public let slots: [CodeSignatureEntitlementBlob]

    public var diagnostic: String {
        switch state {
        case .collected: "Raw XML and/or DER entitlement blobs retained; values and signature validity were not evaluated."
        case .signatureAbsent: "No LC_CODE_SIGNATURE command was found in this slice."
        case .entitlementsAbsent: "No XML or DER entitlement slots were found in the bounded SuperBlob; signature validity was not evaluated."
        case .unexamined: "Raw signature parsing is limited to little-endian ARM64 and ARM64e slices."
        case .malformed:
            switch problem {
            case .duplicateCommand: "Multiple LC_CODE_SIGNATURE commands make this slice ambiguous."
            case .invalidSignatureRange: "The signature command has an invalid size or range, or overlaps the header/load commands."
            default: "The retained signature region has an invalid or ambiguous SuperBlob layout."
            }
        case .budgetExceeded:
            problem == .slotBudget ? "The SuperBlob slot count exceeds the recorded parsing budget."
                : "The signature exceeds the recorded per-slice or aggregate byte budget."
        }
    }

    var supportsSignatureParsing: Bool {
        cpuType == 0x0100000c && [UInt32(0), 1, 2].contains(cpuSubtype & 0x00ffffff) && headerMagic == 0xcffaedfe
    }
}

/// Portable historical byte evidence. This value carries no source URL, open
/// descriptor or reusable discovery capability. Import can reconcile retained
/// signature bytes, but cannot authenticate the unavailable original image.
public struct CodeSignatureEvidence: Codable, Equatable, Sendable {
    public let componentID: UUID
    public let componentRelativePath: String
    public let containerSHA256: String
    public let containerByteCount: UInt64
    public let bytesHashed: UInt64
    public let headerBytesRead: Int
    public let signatureBytesRead: Int
    public let limits: CodeSignatureEvidenceLimits
    public let slices: [CodeSignatureSliceEvidence]

    public func validate() throws {
        try limits.validate()
        let path = componentRelativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count >= 3, path.first == "Contents", componentRelativePath.utf8.count <= 4096,
              path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }),
              containerByteCount > 0, containerByteCount <= limits.maximumContainerBytes,
              Self.isDigest(containerSHA256), bytesHashed == containerByteCount,
              headerBytesRead > 0, headerBytesRead <= limits.maximumHeaderBytes,
              signatureBytesRead >= 0, signatureBytesRead <= limits.maximumTotalSignatureBytes,
              !slices.isEmpty, slices.count <= 64 else { throw CodeSignatureEvidenceError.invalid }
        var architectures = Set<String>(), retained = 0
        for (index, slice) in slices.enumerated() {
            guard slice.index == index, slice.sliceSize > 0, slice.sliceOffset <= containerByteCount,
                  slice.sliceSize <= containerByteCount - slice.sliceOffset,
                  Self.isDigest(slice.sliceSHA256),
                  architectures.insert("\(slice.cpuType):\(slice.cpuSubtype & 0x00ffffff)").inserted,
                  [UInt32(0xcffaedfe), 0xfeedfacf, 0xcefaedfe, 0xfeedface].contains(slice.headerMagic) else {
                throw CodeSignatureEvidenceError.invalid
            }
            let wide = [UInt32(0xcffaedfe), 0xfeedfacf].contains(slice.headerMagic)
            let headerSize: UInt64 = wide ? 32 : 28
            guard (slice.cpuType & 0x03000000 != 0) == wide,
                  slice.sliceSize >= headerSize,
                  slice.loadCommandsEnd >= slice.sliceOffset + headerSize,
                  slice.loadCommandsEnd <= slice.sliceOffset + slice.sliceSize else { throw CodeSignatureEvidenceError.invalid }
            if let offset = slice.signatureOffset, let count = slice.signatureByteCount {
                let end = slice.sliceOffset + slice.sliceSize
                guard count > 0, offset >= slice.loadCommandsEnd, offset <= end, count <= end - offset else {
                    throw CodeSignatureEvidenceError.invalid
                }
            } else if slice.signatureOffset != nil || slice.signatureByteCount != nil { throw CodeSignatureEvidenceError.invalid }
            let remaining = limits.maximumTotalSignatureBytes - retained
            if let bytes = slice.signatureBytes {
                guard bytes.count <= limits.maximumSignatureBytes, bytes.count <= remaining,
                      UInt64(bytes.count) == slice.signatureByteCount, let hash = slice.signatureSHA256,
                      hash == signatureEvidenceSHA256(bytes) else { throw CodeSignatureEvidenceError.invalid }
                retained += bytes.count
            } else if slice.signatureSHA256 != nil { throw CodeSignatureEvidenceError.invalid }
            try validate(slice, remaining: remaining)
        }
        let sorted = slices.sorted { $0.sliceOffset < $1.sliceOffset }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            guard next.sliceOffset >= previous.sliceOffset + previous.sliceSize else { throw CodeSignatureEvidenceError.invalid }
        }
        guard retained == signatureBytesRead else { throw CodeSignatureEvidenceError.invalid }
    }

    private func validate(_ slice: CodeSignatureSliceEvidence, remaining: Int) throws {
        let noPayload = slice.signatureBytes == nil && slice.slots.isEmpty
        let noRange = slice.signatureOffset == nil && slice.signatureByteCount == nil
        switch slice.state {
        case .unexamined:
            guard !slice.supportsSignatureParsing, slice.problem == .unsupportedArchitecture, noPayload, noRange else { throw CodeSignatureEvidenceError.invalid }
        case .signatureAbsent:
            guard slice.supportsSignatureParsing, slice.problem == nil, noPayload, noRange else { throw CodeSignatureEvidenceError.invalid }
        case .collected, .entitlementsAbsent:
            guard slice.supportsSignatureParsing, slice.problem == nil,
                  let bytes = slice.signatureBytes, let offset = slice.signatureOffset else { throw CodeSignatureEvidenceError.invalid }
            let expected = try BoundedCodeSignatureParser.parse(bytes, containerOffset: offset, sliceOffset: slice.sliceOffset, maximumSlotCount: limits.maximumSlotCount)
            guard expected == slice.slots, (slice.state == .entitlementsAbsent) == expected.isEmpty else { throw CodeSignatureEvidenceError.invalid }
        case .malformed:
            guard slice.supportsSignatureParsing, slice.slots.isEmpty else { throw CodeSignatureEvidenceError.invalid }
            if slice.problem == .duplicateCommand || slice.problem == .invalidSignatureRange {
                guard noPayload, noRange else { throw CodeSignatureEvidenceError.invalid }
            } else {
                guard slice.problem == .invalidSuperBlob, let bytes = slice.signatureBytes,
                      let offset = slice.signatureOffset else { throw CodeSignatureEvidenceError.invalid }
                do {
                    _ = try BoundedCodeSignatureParser.parse(bytes, containerOffset: offset, sliceOffset: slice.sliceOffset, maximumSlotCount: limits.maximumSlotCount)
                    throw CodeSignatureEvidenceError.invalid
                } catch BoundedCodeSignatureError.malformed { /* Reproduced from retained bytes. */ }
            }
        case .budgetExceeded:
            guard slice.supportsSignatureParsing, slice.slots.isEmpty, let count = slice.signatureByteCount else { throw CodeSignatureEvidenceError.invalid }
            if slice.problem == .signatureBudget {
                guard noPayload, count > UInt64(limits.maximumSignatureBytes) || count > UInt64(remaining) else { throw CodeSignatureEvidenceError.invalid }
            } else {
                guard slice.problem == .slotBudget, let bytes = slice.signatureBytes,
                      let offset = slice.signatureOffset else { throw CodeSignatureEvidenceError.invalid }
                do {
                    _ = try BoundedCodeSignatureParser.parse(bytes, containerOffset: offset, sliceOffset: slice.sliceOffset, maximumSlotCount: limits.maximumSlotCount)
                    throw CodeSignatureEvidenceError.invalid
                } catch BoundedCodeSignatureError.slotBudget { /* Reproduced from retained bytes. */ }
            }
        }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

func signatureEvidenceSHA256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
