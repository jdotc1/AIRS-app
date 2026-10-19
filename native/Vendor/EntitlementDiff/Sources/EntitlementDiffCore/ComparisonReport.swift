import Foundation

public enum ReportError: Error, Sendable, LocalizedError {
    case architectureMismatch
    case inconsistentSnapshot
    case missingSigningIdentifier
    public var errorDescription: String? {
        switch self {
        case .architectureMismatch: "The two snapshots must use the same requested architecture."
        case .missingSigningIdentifier: "A report snapshot must contain a nonempty signing identifier."
        case .inconsistentSnapshot: "A snapshot marks entitlements absent but contains entitlement entries."
        }
    }
}

public struct ComparisonReport: Sendable, Encodable {
    public let schemaVersion = 1
    public let tool = "EntitlementDiff"
    public let scope = "Requested architecture of the main executable only; nested code and other slices excluded."
    public let signatureValidation = "notPerformed"
    public let gatekeeperAssessment = "notPerformed"
    public let previous: EntitlementSnapshot
    public let current: EntitlementSnapshot
    /// The validated pair's complete comparison, shared with presentation clients.
    /// Kept out of schema 1; exports continue to contain changes and both snapshots.
    public let comparison: EntitlementComparison
    public let changes: [EntitlementChange]
    public let unchangedCount: Int
    public let notices: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tool, scope, signatureValidation, gatekeeperAssessment
        case previous, current, changes, unchangedCount, notices
    }

    public init(previous: EntitlementSnapshot, current: EntitlementSnapshot) throws {
        guard previous.architecture == current.architecture else { throw ReportError.architectureMismatch }
        for snapshot in [previous, current] {
            guard !snapshot.signingIdentifier.isEmpty else { throw ReportError.missingSigningIdentifier }
            if snapshot.presence == .notPresent && !snapshot.entitlements.entries.isEmpty {
                throw ReportError.inconsistentSnapshot
            }
        }
        self.previous = previous
        self.current = current
        comparison = EntitlementComparison(previous: previous.entitlements, current: current.entitlements)
        changes = comparison.changes
        unchangedCount = comparison.rows.count - changes.count
        var notices = [
            "Extracted declarations are not effective permissions or a security verdict.",
            "Unverified signatures may produce partial information. Inputs are not an atomic filesystem snapshot.",
            "Reports omit source paths but include potentially sensitive names, identifiers and entitlement values."
        ]
        if !previous.signingIdentifier.utf8.elementsEqual(current.signingIdentifier.utf8) {
            notices.append("Signing identifiers differ; verify that these are the intended builds.")
        }
        if previous.presence != current.presence {
            notices.append("Entitlement representation changed between absent and dictionary-present.")
        }
        if previous.origin == .syntheticExample || current.origin == .syntheticExample {
            notices.append("Contains synthetic example data; not an inspection of installed applications.")
        }
        if previous.isSavedBaseline || current.isSavedBaseline {
            notices.append("Contains a saved-report snapshot: unverified metadata, not a fresh native inspection.")
        }
        self.notices = notices
    }

    /// Stable key order, sorted entries, no timestamps, paths, UUIDs or locale-dependent values.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public func text() -> String {
        var lines = [
            "EntitlementDiff — complete comparison",
            "Previous: \(DisplayText.quoted(previous.sourceName))",
            "Current: \(DisplayText.quoted(current.sourceName))",
            "Requested architecture: \(previous.architecture.rawValue)",
            "Scope: \(scope)",
            "Signature validity: not checked. Gatekeeper/notarization: not checked.",
            "Previous signing identifier: \(DisplayText.quoted(previous.signingIdentifier))",
            "Current signing identifier: \(DisplayText.quoted(current.signingIdentifier))",
            "Previous entitlement representation: \(previous.presence.rawValue)",
            "Current entitlement representation: \(current.presence.rawValue)",
            "Changes: \(changes.count); unchanged keys: \(unchangedCount).", ""
        ]
        for notice in notices { lines.append("Note: " + notice) }
        if changes.isEmpty { lines += ["", "No entitlement-value changes found in the captured scope."] }
        for change in changes {
            lines += ["", "\(change.kind.rawValue.uppercased()) \(DisplayText.quoted(change.key))",
                      "  Previous: \(change.previous?.rendered ?? "<absent>")",
                      "  Current: \(change.current?.rendered ?? "<absent>")"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
