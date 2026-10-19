import Foundation

/// Accessed exclusively by ComparisonModel on MainActor. The non-observable
/// container owns task cancellation on destruction; it is never sent to another
/// actor. No lock, unsafe Sendable conformance, or actor bypass is required.
final class InspectionRequests {
    var generations: [ComparisonSide: UUID] = [:]
    var tasks: [ComparisonSide: Task<Void, Never>] = [:]
    var sourceURLs: [ComparisonSide: URL] = [:]

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
