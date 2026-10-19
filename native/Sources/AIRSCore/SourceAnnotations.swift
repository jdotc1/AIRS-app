import Foundation

/// Source-only labels, bound to an existing report; never another verdict input.
public struct SourceAnnotations: Codable, Sendable {
    public let schemaVersion: Int
    public let status: String
    public let imageIdentity: SourceImageIdentity
    public let attachment: SymbolAttachment?
    public let inlineChain: String
    public let functions: [FunctionSource]
    public let message: String
    public let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", imageIdentity = "image_identity", inlineChain = "inline_chain"
        case status, attachment, functions, message, limitations
    }

    func validate(image: ImageInfo, findings: [Finding]) throws {
        let statuses: Set<String> = ["matched", "missing_dsym", "missing_image_uuid", "missing_dsym_uuid", "uuid_mismatch", "architecture_mismatch", "ambiguous_dsym", "missing_line_table", "invalid_dsym", "invalid_debug_data", "unsupported_debug_format", "resource_limit"]
        guard schemaVersion == 1, statuses.contains(status), inlineChain == "not_evaluated",
              imageIdentity.architecture == image.architecture, imageIdentity.cpuSubtype == image.cpuSubtype,
              imageIdentity.uuid == image.uuid, imageIdentity.sliceSHA256 == image.sliceSHA256,
              imageIdentity.preferredBase == image.preferredBase,
              imageIdentity.containerSHA256 == image.containerSHA256, imageIdentity.sliceOffset == image.sliceOffset,
              imageIdentity.sliceSize == image.sliceSize,
              Self.validText(message), limitations.count <= 32, limitations.allSatisfy(Self.validText),
              functions.count <= 50_000 else { throw Self.invalid() }
        let requiresAttachment = ["matched", "missing_line_table", "invalid_debug_data", "unsupported_debug_format"]
        guard !requiresAttachment.contains(status) || attachment != nil,
              attachment == nil || (requiresAttachment + ["resource_limit"]).contains(status) else { throw Self.invalid() }
        if let attachment {
            guard attachment.architecture == image.architecture, attachment.cpuSubtype == image.cpuSubtype,
                  let sourceUUID = UUID(uuidString: attachment.uuid), let imageUUID = image.uuid.flatMap(UUID.init(uuidString:)), sourceUUID == imageUUID,
                  Self.validText(attachment.path), attachment.path.hasPrefix("/"),
                  attachment.sliceSHA256.utf8.count == 64,
                  attachment.sliceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (0..<(1 << 31)).contains(attachment.sliceOffset), (0...(128 * 1024 * 1024)).contains(attachment.sliceSize)
            else { throw Self.invalid() }
        }
        guard status == "matched" else {
            guard functions.isEmpty else { throw Self.invalid() }
            return
        }
        guard attachment != nil, functions.count == findings.count else { throw Self.invalid() }
        let byID = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })
        let nameCounts = Dictionary(grouping: findings, by: { $0.function.name }).mapValues(\.count)
        var seen = Set<String>()
        for source in functions {
            guard let finding = byID[source.findingID], seen.insert(source.findingID).inserted,
                  source.pc == finding.function.address, source.nameStatus == (nameCounts[finding.function.name, default: 0] > 1 ? "duplicate" : "unique"),
                  (0...200_000).contains(source.candidateCount), source.locations.count == min(source.candidateCount, 8),
                  source.status == (source.candidateCount == 0 ? "no_line_entry" : source.candidateCount == 1 ? "mapped" : "ambiguous_line")
            else { throw Self.invalid() }
            for location in source.locations {
                guard !location.path.isEmpty, Self.validText(location.path), ["available_unverified", "missing", "unavailable", "relative_path_unresolved"].contains(location.sourceStatus),
                      (0..<(1 << 31)).contains(location.line), (0..<(1 << 31)).contains(location.column),
                      (0..<(1 << 31)).contains(location.discriminator),
                      (location.sourceStatus == "relative_path_unresolved") != location.path.hasPrefix("/")
                else { throw Self.invalid() }
            }
        }
    }

    private static func validText(_ value: String) -> Bool {
        value.unicodeScalars.count <= 4096 && !value.utf8.contains(0)
    }

    private static func invalid() -> ReportError {
        .invalidContents("Source annotations are malformed or do not match the audit image/findings.")
    }
}

public struct SourceImageIdentity: Codable, Sendable {
    public let architecture: String
    public let cpuSubtype: Int
    public let uuid: String?
    public let sliceSHA256: String
    public let preferredBase: String
    public let containerSHA256: String
    public let sliceOffset: Int
    public let sliceSize: Int
    enum CodingKeys: String, CodingKey {
        case architecture, uuid
        case cpuSubtype = "cpu_subtype", sliceSHA256 = "slice_sha256", preferredBase = "preferred_base"
        case containerSHA256 = "container_sha256", sliceOffset = "slice_offset", sliceSize = "slice_size"
    }
}

public struct SymbolAttachment: Codable, Sendable {
    public let path: String
    public let architecture: String
    public let cpuSubtype: Int
    public let uuid: String
    public let sliceSHA256: String
    public let sliceOffset: Int
    public let sliceSize: Int
    enum CodingKeys: String, CodingKey {
        case path, architecture, uuid
        case cpuSubtype = "cpu_subtype", sliceSHA256 = "slice_sha256", sliceOffset = "slice_offset", sliceSize = "slice_size"
    }
}

public struct FunctionSource: Codable, Sendable {
    public let findingID: String
    public let pc: String
    public let status: String
    public let nameStatus: String
    public let candidateCount: Int
    public let locations: [SourceLocation]
    enum CodingKeys: String, CodingKey {
        case pc, status, locations
        case findingID = "finding_id", nameStatus = "name_status", candidateCount = "candidate_count"
    }
}

public struct SourceLocation: Codable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int
    public let discriminator: Int
    public let sourceStatus: String
    enum CodingKeys: String, CodingKey {
        case path, line, column, discriminator
        case sourceStatus = "source_status"
    }
}

extension ReportFiles {
    /// Only annotations may change. Unknown original fields must survive too.
    public static func decodeSymbolEnrichment(original: Data, enriched: Data) throws -> AuditReport {
        let report = try AuditReport.decode(enriched)
        guard let annotations = report.sourceAnnotations, annotations.attachment != nil else {
            throw SymbolAttachmentError.rejected(report.sourceAnnotations?.message ?? "The dSYM could not be attached.")
        }
        guard var before = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var after = try JSONSerialization.jsonObject(with: enriched) as? [String: Any] else {
            throw ReportError.invalidContents("Expected an audit JSON object for dSYM attachment.")
        }
        before.removeValue(forKey: "source_annotations")
        after.removeValue(forKey: "source_annotations")
        guard try JSONSerialization.data(withJSONObject: before, options: .sortedKeys)
            == JSONSerialization.data(withJSONObject: after, options: .sortedKeys) else {
            throw ReportError.invalidContents("The symbol result changed audit evidence or omitted original fields.")
        }
        return report
    }
}

/// An attachment mismatch does not make the original audit inconsistent.
public enum SymbolAttachmentError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? {
        switch self {
        case .rejected(let message): return message
        }
    }
}
