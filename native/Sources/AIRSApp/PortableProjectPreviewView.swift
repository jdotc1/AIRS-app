import SwiftUI

struct PortableProjectPreviewView: View {
    let preview: PortableProjectPreview
    let busy: Bool
    let confirm: () -> Void
    let cancel: () -> Void
    @State private var confirmedOriginalEvidence = false

    var body: some View {
        GroupBox(preview.purpose == .export ? "Portable Project Export" : "Reconstruct Portable Project") {
            VStack(alignment:.leading,spacing:8) {
                Text(preview.project.name).font(.headline)
                Text("\(preview.project.evidence.count) original evidence archives · \(preview.project.annotations.count) notes · \(preview.project.batchLinks.count) historical batch associations")
                Text("Original evidence and notes are included verbatim and may contain sensitive strings or source paths. Original apps, dSYMs and batch checkpoints are excluded.")
                    .foregroundStyle(.secondary)
                if preview.purpose == .reconstruct {
                    Text(preview.settledAdmission == nil
                        ? "Creates a separate new store and opens it for review. Your current store is preserved; you can return to it. Batch associations remain historical references."
                        : "Creates a separate new store with detached historical outcomes. Your current store is preserved; no queue is restored and no comparison report is included.")
                }
                if let settled=preview.settledAdmission {HistoricalBatchOutcomesView(history:settled.history)}
                DisclosureGroup("Included records and notes") {
                    ScrollView {
                        VStack(alignment:.leading,spacing:6) {
                            ForEach(preview.project.evidence) { record in
                                Text(record.kinds.joined(separator:", ")+" · "+record.id.uuidString).textSelection(.enabled)
                                if preview.project.pinnedBaselineID == record.id {Text("Pinned baseline").foregroundStyle(.secondary)}
                            }
                            ForEach(preview.project.annotations) {note in Text(note.text).textSelection(.enabled)}
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:160)
                }
                if preview.purpose == .export {
                    Toggle("Include the original evidence and all project notes",isOn:$confirmedOriginalEvidence)
                }
                HStack {
                    Button("Cancel Preview",action:cancel).disabled(busy)
                    Spacer()
                    Button(preview.purpose == .export ? "Choose Export Destination…" : "Choose New Store Destination…",action:confirm)
                        .disabled(busy || (preview.purpose == .export && !confirmedOriginalEvidence))
                }
            }.padding(6)
        }
        .id(preview.id)
    }
}
