import Foundation
import SwiftUI
import AIRSCore
import AIRSEntitlements

struct ArchiveReview: Identifiable {
    let id = UUID()
    let archive: InspectionArchive
    let bytes: Data
    let sourceURL: URL
    let auditRevision: UUID
    let entitlementRevision: UUID
}

/// The user explicitly chooses one evidence UUID. Opening an archive never
/// substitutes its first attachment or treats an opaque payload as an assessment.
struct ArchiveReviewView: View {
    let review: ArchiveReview
    let open: (UUID) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Archive").font(.title2).bold()
            Text("Choose an evidence record to open. Supported means its report format was parsed; it does not establish trust, safety or effective permissions.")
            Text("\(review.archive.attachments.count) evidence records · \(review.archive.components.count) component references")
                .foregroundStyle(.secondary)
            List(review.archive.attachments) { item in
                ArchiveEvidenceRow(item: item, open: { open(item.id) })
            }
            HStack { Spacer(); Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(minWidth: 640, idealWidth: 760, minHeight: 400, idealHeight: 520)
    }
}

private struct ArchiveEvidenceRow: View {
    let item: EvidenceAttachment
    let open: () -> Void
    // The immutable archive has already validated recognized payloads before
    // publication. Do not reparse/hash blobs during SwiftUI body evaluation.
    private var supported: Bool {
        item.schemaVersion == 1 && item.mediaType == "application/json" &&
            ["airs.inspection", "airs.audit", "EntitlementDiff", "airs.components", "airs.component.review", "airs.assessments", CodeSignatureEvidenceDocument.kind].contains(item.kind)
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.kind).bold()
                Text(item.id.uuidString).font(.caption).textSelection(.enabled)
                Text("Schema \(item.schemaVersion) · \(item.byteCount) bytes · \(supported ? "Supported format" : "Uninterpreted")")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Evidence", action: open).disabled(!supported)
        }.padding(.vertical, 4)
    }
}
