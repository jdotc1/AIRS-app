import Foundation
import EntitlementDiffCore
import EntitlementDiffModel

/// Recorded context accompanies, but never changes, the strict schema-1 JSON.
enum InspectionSummary {
    static func text(report: EntitlementDiffCore.ComparisonReport,
                     contexts: [ComparisonSide: InspectionCaptureContext]) -> String {
        var lines = ["AIRS Text Summary", "Recorded capture labels are unverified. Entitlements are declarations, not effective permissions or a trust verdict."]
        for side in ComparisonSide.allCases {
            guard let context = contexts[side] else {
                lines.append("\(side.label): capture metadata unavailable (legacy or uncaptured input).")
                continue
            }
            let document = context.document
            lines.append("\(side.label): \(context.label ?? document.snapshot.sourceName)")
            lines.append("Captured: \(document.capturedAt.ISO8601Format()); architecture: \(document.snapshot.architecture.rawValue)")
            lines.append("Recorded identifier: \(document.identity?.bundleIdentifier ?? "unavailable"); version: \(document.identity?.version ?? "unavailable"); build: \(document.identity?.build ?? "unavailable")")
            lines.append("Scope: main executable, requested architecture. Recorded origin: \(document.captureProvenance.rawValue). Original binary not retained; signature and Gatekeeper assessments not performed.")
        }
        lines.append("Text Summary lists differences and an unchanged count. Complete typed evidence is in the comparison JSON.")
        return lines.joined(separator: "\n") + "\n\n" + report.text()
    }
}
