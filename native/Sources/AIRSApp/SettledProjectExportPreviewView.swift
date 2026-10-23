import SwiftUI

struct SettledProjectExportPreviewView:View {
    let preview:SettledProjectExportPreview
    let busy:Bool
    let confirm:()->Void
    let cancel:()->Void
    @State private var consent=false
    var body:some View {
        GroupBox(preview.purpose == .export ? "Export project with recorded outcomes" : "Re-export recipient historical outcomes") {
            VStack(alignment:.leading,spacing:8) {
                Text(preview.package.project.name).font(.headline)
                Text("Project \(preview.package.project.id.uuidString) · Revision \(preview.package.project.revision)").textSelection(.enabled)
                Text("Original evidence, project notes and outcome messages are included verbatim and may contain sensitive strings or paths. No comparison reports, original apps or execution checkpoints are included.")
                Text("Historical snapshot only. No queue is restored; audit outcomes remain unsupported. Recorded library IDs do not authenticate original library provenance.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(preview.history.outcomes,id:\.link.id) {outcome in
                            DisclosureGroup(outcome.link.family.rawValue+" · recorded library ID "+outcome.link.historyID.uuidString) {
                                if let reason=outcome.absence {Text("Outcome unavailable: "+reason.rawValue)}
                                else {
                                    Text("Recorded cancellation: "+(outcome.cancelled.map{$0 ? "yes":"no"} ?? "not recorded"))
                                    ForEach(outcome.rows,id:\.id) {row in
                                        Text(row.status.title+" · "+row.message)
                                        Text("Changed: "+(row.changedCount.map{String($0)} ?? "not recorded")+" · Unchanged: "+(row.unchangedCount.map{String($0)} ?? "not recorded"))
                                        Text(row.reportIncluded ? "Report included":"Comparison report not included")
                                    }
                                }
                            }
                        }
                        ForEach(preview.package.project.annotations) {note in Text(note.text)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:200)
                Toggle("Include original evidence, all project notes and recorded outcomes",isOn:$consent)
                HStack {
                    Button("Cancel Preview",action:cancel).disabled(busy)
                    Spacer()
                    Button("Choose New Companion Destination…",action:confirm).disabled(busy || !consent)
                }
            }.padding(6)
        }.id(preview.id)
    }
}
