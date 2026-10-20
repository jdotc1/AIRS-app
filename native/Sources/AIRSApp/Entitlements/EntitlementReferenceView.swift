import SwiftUI
import AIRSEntitlements

struct EntitlementReferenceView: View {
    let key: String
    var body: some View {
        if let reference = EntitlementReferenceCatalog.reference(forExactKey: key) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reference.explanation)
                Text(reference.scopeNote).foregroundStyle(.secondary)
                Link("Apple documentation · reviewed \(reference.reviewedDate)", destination: reference.sourceURL)
            }.font(.caption).textSelection(.enabled)
        }
    }
}
