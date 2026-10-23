import Foundation

extension PortableSettledBatchEvidence {
    /// Capture linked outcomes from one explicitly selected source history. The
    /// library, rather than a caller-authored dictionary, supplies the association
    /// between each history ID and its original admitted record bytes.
    public static func prepare(project: InspectionProject, history: EntitlementBatchHistory) async throws -> Self {
        try project.validate()
        try Task.checkCancellation()
        let ids = Set(project.batchLinks.filter { $0.family == .entitlements }.map(\.historyID))
        let records = try await history.portableRecords(for: ids)
        try Task.checkCancellation()
        return try prepare(project: project, records: records)
    }
}
