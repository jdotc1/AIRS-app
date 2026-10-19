import Foundation

public struct ComparisonReport: Decodable, Sendable {
    public let schemaVersion: Int
    public let reportKind: String
    public let comparison: ComparisonContext
    public let summary: ComparisonSummary
    public let changes: [ComparisonChange]
    public let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reportKind = "report_kind"
        case comparison, summary, changes, limitations
    }

    public static func decode(_ data: Data) throws -> ComparisonReport {
        let report = try JSONDecoder().decode(ComparisonReport.self, from: data)
        guard report.schemaVersion == 1, report.reportKind == "airs.diff" else {
            throw ReportError.invalidContents("Unsupported comparison format.")
        }
        let counts = [report.summary.matchedCount, report.summary.changedCount,
                      report.summary.unchangedCount, report.summary.addedCount,
                      report.summary.removedCount, report.summary.ambiguousCount]
        guard counts.allSatisfy({ $0 >= 0 }) else {
            throw ReportError.invalidContents("Comparison counts must be nonnegative.")
        }
        return report
    }
}

public struct ComparisonContext: Decodable, Sendable {
    public let baselineImage: ComparisonImage
    public let currentImage: ComparisonImage
    public let sameImage: Bool
    public let modelCompatible: Bool
    public let matchingPolicy: String

    enum CodingKeys: String, CodingKey {
        case baselineImage = "baseline_image"
        case currentImage = "current_image"
        case sameImage = "same_image"
        case modelCompatible = "model_compatible"
        case matchingPolicy = "matching_policy"
    }
}

public struct ComparisonImage: Decodable, Sendable {
    public let displayName: String
    public let uuid: String?
    public let sliceSHA256: String
    public let architecture: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case uuid, architecture
        case sliceSHA256 = "slice_sha256"
    }
}

public struct ComparisonSummary: Decodable, Sendable {
    public let matchedCount: Int
    public let changedCount: Int
    public let unchangedCount: Int
    public let addedCount: Int
    public let removedCount: Int
    public let ambiguousCount: Int

    enum CodingKeys: String, CodingKey {
        case matchedCount = "matched_count"
        case changedCount = "changed_count"
        case unchangedCount = "unchanged_count"
        case addedCount = "added_count"
        case removedCount = "removed_count"
        case ambiguousCount = "ambiguous_count"
    }
}

public struct ComparisonChange: Decodable, Sendable {
    public let key: String
    public let matchBasis: String
    public let functionName: String
    public let baselineID: String?
    public let currentID: String?
    public let change: String
    public let beforeVerdict: AuditVerdict?
    public let afterVerdict: AuditVerdict?
    public let beforeScope: String?
    public let afterScope: String?
    public let notes: [String]

    enum CodingKeys: String, CodingKey {
        case key, change, notes
        case matchBasis = "match_basis"
        case functionName = "function_name"
        case baselineID = "baseline_id"
        case currentID = "current_id"
        case beforeVerdict = "before_verdict"
        case afterVerdict = "after_verdict"
        case beforeScope = "before_scope"
        case afterScope = "after_scope"
    }
}
