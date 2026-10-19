import Foundation

/// Report vocabulary is deliberately narrower than a whole-image correctness claim.
public enum AuditVerdict: String, Codable, CaseIterable, Identifiable, Sendable {
    case agreement
    case inconsistency
    case unresolved

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agreement: return "Agreement within scope"
        case .inconsistency: return "Supported inconsistency"
        case .unresolved: return "Unresolved"
        }
    }

    public var systemImage: String {
        switch self {
        case .agreement: return "equal.circle"
        case .inconsistency: return "exclamationmark.triangle"
        case .unresolved: return "questionmark.circle"
        }
    }
}

/// Evidence values can be structured. Keep their types rather than assuming prose.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([JSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let decoded): try value.encode(decoded)
        case .integer(let decoded): try value.encode(decoded)
        case .number(let decoded): try value.encode(decoded)
        case .string(let decoded): try value.encode(decoded)
        case .array(let decoded): try value.encode(decoded)
        case .object(let decoded): try value.encode(decoded)
        }
    }

    public var displayText: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "Unavailable" }
        return text
    }
}

public struct AuditReport: Codable, Sendable {
    public let schemaVersion: Int
    public let reportKind: String
    public let generator: GeneratorInfo
    public let image: ImageInfo
    public let summary: ReportSummary
    public let issues: [InputIssue]
    public let metadataRanges: [MetadataRange]
    public let findings: [Finding]
    public let limitations: [String]
    public let sourceAnnotations: SourceAnnotations?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportKind = "report_kind"
        case generator, image, summary, issues, findings, limitations
        case metadataRanges = "metadata_ranges"
        case sourceAnnotations = "source_annotations"
    }

    public static func decode(_ data: Data) throws -> AuditReport {
        let decoder = JSONDecoder()
        let header = try decoder.decode(ReportHeader.self, from: data)
        guard header.schemaVersion == 1 else {
            throw ReportError.unsupportedSchema(header.schemaVersion)
        }
        guard header.reportKind == "airs.audit" else {
            throw ReportError.wrongKind(header.reportKind)
        }
        let report = try decoder.decode(AuditReport.self, from: data)
        try report.validate()
        try report.sourceAnnotations?.validate(image: report.image, findings: report.findings)
        return report
    }

    private func validate() throws {
        let counts = [summary.functionCount, summary.agreementCount,
                      summary.inconsistencyCount, summary.unresolvedCount,
                      summary.metadataEntryCount, summary.checkedPCCount]
        guard counts.allSatisfy({ $0 >= 0 }) else {
            throw ReportError.invalidContents("Summary counts must be nonnegative.")
        }
        guard summary.functionCount == findings.count,
              summary.agreementCount == findings.filter({ $0.verdict == .agreement }).count,
              summary.inconsistencyCount == findings.filter({ $0.verdict == .inconsistency }).count,
              summary.unresolvedCount == findings.filter({ $0.verdict == .unresolved }).count,
              summary.metadataEntryCount == metadataRanges.count,
              summary.checkedPCCount == findings.reduce(0, { $0 + $1.checkedPCs.count }) else {
            throw ReportError.invalidContents("Summary counts do not match the findings.")
        }
        guard findings.count <= 50_000,
              Set(findings.map(\.id)).count == findings.count,
              findings.allSatisfy({ $0.id.hasPrefix("airsf-") && Self.isLowerHex(String($0.id.dropFirst("airsf-".count)), count: 64) }) else {
            throw ReportError.invalidContents("Expected at most 50,000 findings with unique AIRS identifiers.")
        }
        guard ["arm64", "arm64e"].contains(image.architecture),
              ["execute", "dylib", "bundle"].contains(image.fileType), image.cpuSubtype >= 0,
              Self.isLowerHex(image.containerSHA256, count: 64),
              Self.isLowerHex(image.sliceSHA256, count: 64),
              image.uuid == nil || UUID(uuidString: image.uuid ?? "") != nil else {
            throw ReportError.invalidContents("Unsupported or malformed image identity.")
        }
        let base = try Self.address(image.preferredBase)
        let modes: Set<String> = ["frame", "frameless", "dwarf", "pauth_frame", "none", "unknown"]
        let coverage: Set<String> = ["compact", "dwarf_reference", "dwarf_evaluated", "none", "unavailable"]
        let scopes: Set<String> = ["synchronous_call_sites", "modeled_leaf_body", "metadata_only"]
        for finding in findings {
            let start = try Self.address(finding.function.address)
            let end = try Self.address(finding.function.endAddress)
            let offset = try Self.address(finding.function.imageOffset)
            guard end > start, end - start == finding.function.size,
                  start >= base, start - base == offset,
                  finding.function.name != nil,
                  finding.instructionCount >= 0, modes.contains(finding.mode),
                  coverage.contains(finding.coverage), scopes.contains(finding.scope) else {
                throw ReportError.invalidContents("Invalid function extent, coverage, or scope.")
            }
            for pc in finding.checkedPCs {
                let address = try Self.address(pc)
                guard address >= start, address < end else {
                    throw ReportError.invalidContents("A checked PC lies outside its function.")
                }
            }
            let encoding: UInt64?
            if let wireEncoding = finding.encoding {
                let value = try Self.address(wireEncoding)
                guard value <= UInt64(UInt32.max) else {
                    throw ReportError.invalidContents("An unwind encoding exceeds 32 bits.")
                }
                encoding = value
            } else {
                encoding = nil
            }
            if finding.verdict != .unresolved {
                guard ["compact", "dwarf_reference", "dwarf_evaluated"].contains(finding.coverage),
                      !finding.checkedPCs.isEmpty, finding.scope != "metadata_only" else {
                    throw ReportError.invalidContents("Agreement or inconsistency needs metadata coverage, a checked PC, and a modeled observation scope.")
                }
                if finding.coverage == "compact" {
                    guard let encoding, encoding != 0 else {
                        throw ReportError.invalidContents("A supported compact finding requires a nonzero 32-bit encoding, regardless of analysis model.")
                    }
                }
                if ["arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31"].contains(generator.analysisModelVersion) {
                    guard image.architecture == "arm64", [0, 1].contains(image.cpuSubtype) else {
                        throw ReportError.invalidContents("v3 supported findings require an exact ordinary ARM64 subtype.")
                    }
                }
                if ["arm64-linear-dwarf-v2", "arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31"].contains(generator.analysisModelVersion), finding.mode == "dwarf" {
                    guard image.architecture == "arm64", [0, 1].contains(image.cpuSubtype),
                          finding.coverage == "dwarf_evaluated",
                          finding.function.boundarySource == "lc_function_starts",
                          let encoding, encoding & 0x0F00_0000 == 0x0300_0000 else {
                        throw ReportError.invalidContents("Supported evaluated CFI requires evaluated coverage, ordinary ARM64 subtype, independent boundaries, and a DWARF encoding.")
                    }
                } else if ["arm64-linear-v1", "arm64-linear-dwarf-v2", "arm64-bounded-cfg-v3", "arm64-bounded-calls-v4", "arm64-bounded-dwarf-cfg-v5", "arm64-bounded-returns-v6", "arm64-bounded-teardowns-v7", "arm64-bounded-suffixes-v8", "arm64-bounded-conditional-v9", "arm64-bounded-conditions-v10", "arm64-bounded-flags-v11", "arm64-bounded-register-flags-v12", "arm64-bounded-shifted-flags-v13", "arm64-bounded-extended-flags-v14", "arm64-bounded-logical-flags-v15", "arm64-bounded-logical-immediate-v16", "arm64-bounded-nonflag-immediate-v17", "arm64-bounded-nonflag-register-v18", "arm64-bounded-carry-v19", "arm64-bounded-conditional-compare-v20", "arm64-bounded-conditional-select-v21", "arm64-bounded-bitfield-v22", "arm64-bounded-extract-v23", "arm64-bounded-variable-shift-v24", "arm64-bounded-multiply-v25", "arm64-bounded-widening-multiply-v26", "arm64-bounded-high-multiply-v27", "arm64-bounded-loops-v28", "arm64-bounded-loop-calls-v29", "arm64-bounded-cfa-register-v30", "arm64-bounded-sequential-loops-v31"].contains(generator.analysisModelVersion) {
                    try validateLinearSupportedFinding(finding, encoding: encoding)
                }
            }
            if generator.analysisModelVersion == "arm64-linear-v1", finding.coverage == "dwarf_evaluated" {
                throw ReportError.invalidContents("Historical v1 has no evaluated CFI coverage.")
            }
            for evidence in finding.evidence {
                if let address = evidence.address { _ = try Self.address(address) }
                for value in [evidence.expected, evidence.observed].compactMap({ $0 }) {
                    switch value {
                    case .string, .null: break
                    default:
                        throw ReportError.invalidContents("Schema 1 evidence expected/observed values must be strings or null.")
                    }
                }
            }
        }
        var previousEnd: UInt64 = 0
        for range in metadataRanges {
            let start = try Self.address(range.start)
            let end = try Self.address(range.end)
            let encoding = try Self.address(range.encoding)
            guard end > start, start >= previousEnd, encoding <= UInt64(UInt32.max),
                  modes.contains(range.mode) else {
                throw ReportError.invalidContents("Metadata ranges must be ordered, nonoverlapping, and correctly encoded.")
            }
            previousEnd = end
        }
    }

    /// Check the advertised model's structural relationships, not analysis truth.
    /// Unknown model versions remain importable under the generic report checks.
    private func validateLinearSupportedFinding(_ finding: Finding, encoding: UInt64?) throws {
        guard image.architecture == "arm64", [0, 1].contains(image.cpuSubtype & 0x00FF_FFFF),
              finding.coverage == "compact",
              finding.function.boundarySource == "lc_function_starts" else {
            throw ReportError.invalidContents("arm64-linear-v1 supported findings require ordinary ARM64, compact coverage, and LC_FUNCTION_STARTS boundaries.")
        }
        guard let encoding, encoding != 0 else {
            throw ReportError.invalidContents("arm64-linear-v1 supported findings require a nonzero compact encoding.")
        }

        let allowedBits: UInt64
        switch encoding & 0x0F00_0000 {
        case 0x0400_0000:
            guard finding.mode == "frame", finding.scope == "synchronous_call_sites" else {
                throw ReportError.invalidContents("Frame encoding requires frame mode and synchronous call-site scope in arm64-linear-v1.")
            }
            // Common flags, ARM64 mode, and modeled integer saved-pair bits.
            allowedBits = 0xFF00_001F
        case 0x0200_0000:
            guard finding.mode == "frameless", finding.scope == "modeled_leaf_body",
                  (encoding & 0x1F) == 0 else {
                throw ReportError.invalidContents("Frameless encoding requires modeled leaf-body scope and no saved-pair bits in arm64-linear-v1.")
            }
            allowedBits = 0xFFFF_F01F
        default:
            throw ReportError.invalidContents("arm64-linear-v1 does not support this encoding mode for an agreement or inconsistency.")
        }
        guard (encoding & 0x0000_0F00) == 0, (encoding & ~allowedBits) == 0 else {
            throw ReportError.invalidContents("arm64-linear-v1 supported findings cannot contain SIMD saves or unsupported encoding bits.")
        }
    }

    private static func isLowerHex(_ value: String, count: Int? = nil) -> Bool {
        let bytes = Array(value.utf8)
        if let count, bytes.count != count { return false }
        return !bytes.isEmpty && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func address(_ text: String) throws -> UInt64 {
        let digits = String(text.dropFirst(2))
        guard text.hasPrefix("0x"), digits.utf8.count <= 16, isLowerHex(digits),
              let value = UInt64(digits, radix: 16) else {
            throw ReportError.invalidContents("Expected a lowercase 64-bit hexadecimal address or encoding.")
        }
        return value
    }
}

private struct ReportHeader: Decodable {
    let schemaVersion: Int
    let reportKind: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportKind = "report_kind"
    }
}

public struct GeneratorInfo: Codable, Sendable {
    public let name: String
    public let version: String
    public let analysisModelVersion: String

    enum CodingKeys: String, CodingKey {
        case name, version
        case analysisModelVersion = "analysis_model_version"
    }
}

public struct ImageInfo: Codable, Sendable {
    public let displayName: String
    public let path: String?
    public let architecture: String
    public let cpuSubtype: Int
    public let uuid: String?
    public let containerSHA256: String
    public let sliceSHA256: String
    public let sliceOffset: UInt64
    public let sliceSize: UInt64
    public let preferredBase: String
    public let fileType: String

    enum CodingKeys: String, CodingKey {
        case path, architecture, uuid
        case displayName = "display_name"
        case cpuSubtype = "cpu_subtype"
        case containerSHA256 = "container_sha256"
        case sliceSHA256 = "slice_sha256"
        case sliceOffset = "slice_offset"
        case sliceSize = "slice_size"
        case preferredBase = "preferred_base"
        case fileType = "file_type"
    }
}

public struct ReportSummary: Codable, Sendable {
    public let functionCount: Int
    public let agreementCount: Int
    public let inconsistencyCount: Int
    public let unresolvedCount: Int
    public let metadataEntryCount: Int
    public let checkedPCCount: Int

    enum CodingKeys: String, CodingKey {
        case functionCount = "function_count"
        case agreementCount = "agreement_count"
        case inconsistencyCount = "inconsistency_count"
        case unresolvedCount = "unresolved_count"
        case metadataEntryCount = "metadata_entry_count"
        case checkedPCCount = "checked_pc_count"
    }
}

public struct InputIssue: Codable, Sendable {
    public let code: String
    public let message: String
    public let offset: UInt64?
}

public struct MetadataRange: Codable, Sendable {
    public let start: String
    public let end: String
    public let encoding: String
    public let mode: String
}

public struct Finding: Codable, Identifiable, Sendable {
    public let id: String
    public let function: FunctionInfo
    public let verdict: AuditVerdict
    public let coverage: String
    public let mode: String
    public let scope: String
    public let reasonCodes: [String]
    public let checkedPCs: [String]
    public let instructionCount: Int
    public let encoding: String?
    public let evidence: [Evidence]
    public let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case id, function, verdict, coverage, mode, scope, evidence, limitations, encoding
        case reasonCodes = "reason_codes"
        case checkedPCs = "checked_pcs"
        case instructionCount = "instruction_count"
    }

    public var displayName: String {
        guard let name = function.name, !name.isEmpty else { return function.address }
        return name
    }

    public func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let fields = [displayName, function.address, function.endAddress,
                      function.imageOffset, verdict.title, coverage, mode, scope]
            + reasonCodes + evidence.map(\.message)
        return fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}

public struct FunctionInfo: Codable, Sendable {
    public let name: String?
    public let address: String
    public let endAddress: String
    public let imageOffset: String
    public let size: UInt64
    public let boundarySource: String

    enum CodingKeys: String, CodingKey {
        case name, address, size
        case endAddress = "end_address"
        case imageOffset = "image_offset"
        case boundarySource = "boundary_source"
    }
}

public struct Evidence: Codable, Sendable {
    public let code: String
    public let message: String
    public let address: String?
    public let expected: JSONValue?
    public let observed: JSONValue?
}

public enum ReportError: LocalizedError {
    case unsupportedSchema(Int)
    case wrongKind(String)
    case tooLarge(Int)
    case notRegularFile
    case invalidContents(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This app reads audit schema 1. The selected report uses schema \(version)."
        case .wrongKind(let kind):
            return "Expected an airs.audit report; the selected document is \(kind)."
        case .tooLarge(let limit):
            return "The report exceeds the \(limit / 1_048_576) MiB local import limit."
        case .notRegularFile:
            return "Select a regular JSON report file."
        case .invalidContents(let message):
            return "The audit report is inconsistent: \(message)"
        }
    }
}

public enum ReportFiles {
    public static let maximumBytes = 64 * 1_048_576

    /// Read at most limit + 1 bytes, even if a file grows after its size was checked.
    public static func readBounded(_ url: URL, limit: Int = maximumBytes) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReportError.notRegularFile }
        if let size = values.fileSize, size > limit { throw ReportError.tooLarge(limit) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let chunk = try handle.read(upToCount: min(256 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        guard data.count <= limit else { throw ReportError.tooLarge(limit) }
        return data
    }

    public static func prettyJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let encoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw ReportError.invalidContents("JSON is not UTF-8.")
        }
        return text
    }
}
