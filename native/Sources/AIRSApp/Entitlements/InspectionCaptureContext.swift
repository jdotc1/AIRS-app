import Foundation
import AIRSEntitlements

/// Session-only association. Original document bytes remain immutable.
struct InspectionCaptureContext: Identifiable, Sendable {
    let id = UUID()
    let document: InspectionDocument
    let data: Data
    var sourceURL: URL? = nil
    var label: String? = nil
}

enum InspectionReviewAction { case inspect, useAsPrevious }
