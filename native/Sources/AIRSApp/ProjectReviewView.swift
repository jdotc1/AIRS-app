import SwiftUI
import AIRSCore
import AIRSEntitlements

struct ProjectReviewSession:Identifiable,Sendable {
    let id:UUID
    let entries:[InspectionProjectEntry]
    let project:InspectionProject?
    let evidenceIssues:[UUID:String]
    let unreferenced:[UUID]
    let retentionIssue:String?
    init(id:UUID=UUID(),entries:[InspectionProjectEntry]=[],project:InspectionProject?=nil,evidenceIssues:[UUID:String]=[:],unreferenced:[UUID]=[],retentionIssue:String?=nil) {
        self.id=id;self.entries=entries;self.project=project;self.evidenceIssues=evidenceIssues;self.unreferenced=unreferenced;self.retentionIssue=retentionIssue
    }
}
struct ProjectBatchChoice:Identifiable {
    let family:ProjectBatchLink.Family
    let historyID:UUID
    var id:String {family.rawValue+":"+historyID.uuidString}
    func link() -> ProjectBatchLink {.init(family:family,historyID:historyID,rowIDs:[])}
}
struct ProjectReviewView:View {
    let session:ProjectReviewSession
    let busy:Bool
    let status:String
    let batchCandidates:[ProjectBatchChoice]
    let select:(UUID)->Void
    let create:(String)->Void
    let rename:(String)->Void
    let add:()->Void
    let pin:(UUID?)->Void
    let note:(String,Bool)->Void
    let review:(UUID)->Void
    let export:(UUID)->Void
    let exportMetadata:()->Void
    let portablePreview:PortableProjectPreview?
    let storePath:String
    let canReturnToOriginalStore:Bool
    let previewPortable:()->Void
    let choosePortablePackage:()->Void
    let confirmPortable:()->Void
    let cancelPortable:()->Void
    let returnToOriginalStore:()->Void
    let remove:(UUID)->Void
    let removeUnreferenced:(UUID)->Void
    let removeProject:(UUID)->Void
    let link:(ProjectBatchLink)->Void
    let close:()->Void
    @State private var name=""
    @State private var noteText=""
    @State private var acknowledged=false
    @State private var removal:UUID?
    @State private var orphanRemoval:UUID?
    @State private var projectRemoval:UUID?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Inspection Projects").font(.title2).bold()
            Text("Projects retain original evidence bytes and separate review metadata. Membership or a pinned baseline does not retain an original app or establish trust.")
            Text("Store: \(storePath)").font(.caption).textSelection(.enabled)
            HStack {
                Button("Preview Portable Export…",action:previewPortable).disabled(session.project == nil || portablePreview != nil)
                Button("Reconstruct Package…",action:choosePortablePackage).disabled(portablePreview != nil)
                if canReturnToOriginalStore {Button("Return to Original Store",action:returnToOriginalStore).disabled(portablePreview != nil)}
            }
            if let portablePreview {
                PortableProjectPreviewView(preview:portablePreview,busy:busy,confirm:confirmPortable,cancel:cancelPortable).id(portablePreview.id)
            }
            HStack {
                TextField("Project name",text:$name).textFieldStyle(.roundedBorder)
                Button("New Project") {create(name)}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Button("Rename Selected") {rename(name)}.disabled(session.project == nil)
            }
            .disabled(portablePreview != nil)
            HStack(alignment:.top,spacing:16) {
                List(session.entries) {entry in
                    VStack(alignment:.leading,spacing:4) {
                        Button(entry.project?.name ?? "Unavailable project") {select(entry.id)}
                        if let project=entry.project {Text("Revision \(project.revision) · \(project.evidence.count) records").foregroundStyle(.secondary)}
                        if let issue=entry.issue {Text(issue).foregroundStyle(.secondary);Button("Remove Unavailable Project…") {projectRemoval=entry.id}}
                    }
                }.frame(width:240)
                if let project=session.project {
                    ScrollView {
                        VStack(alignment:.leading,spacing:12) {
                            Text(project.name).font(.headline)
                            Text("Project \(project.id.uuidString) · Revision \(project.revision)").textSelection(.enabled)
                            HStack {
                                Button("Import Evidence…",action:add)
                                Button("Export Project Metadata…",action:exportMetadata)
                                Button("Remove Project…") {projectRemoval=project.id}
                            }
                            Text("Capture history · extraction time, project-added time and annotation time remain distinct. Model/extractor labels are separate from app-version declarations.").foregroundStyle(.secondary)
                            ForEach(project.evidence.sorted {($0.extractionTimes.first ?? $0.savedAt)<($1.extractionTimes.first ?? $1.savedAt)}) {entry in
                                ProjectEvidenceRow(entry:entry,pinned:project.pinnedBaselineID == entry.id,issue:session.evidenceIssues[entry.id],
                                    pin:{pin(project.pinnedBaselineID == entry.id ? nil : entry.id)},review:{review(entry.id)},export:{export(entry.id)},remove:{removal=entry.id})
                                Divider()
                            }
                            if project.evidence.isEmpty {Text("No evidence retained in this project.").foregroundStyle(.secondary)}
                            TextField("Review note (separate from observations)",text:$noteText,axis:.vertical).textFieldStyle(.roundedBorder)
                            Toggle("Acknowledged for this review only",isOn:$acknowledged)
                            Button("Add Review Note") {note(noteText,acknowledged);noteText=""}.disabled(noteText.isEmpty)
                            ForEach(project.annotations.reversed()) {annotation in
                                Text("\(annotation.authoredAt.formatted()) · Acknowledged: \(annotation.acknowledged ? "yes" : "no") · \(annotation.text)").textSelection(.enabled)
                            }
                            DisclosureGroup("Batch associations") {
                                Text("Links are project metadata; settled rows and retry/recovery behavior remain unchanged. Open Batch History first to populate additional saved batch choices.").foregroundStyle(.secondary)
                                ForEach(batchCandidates) {candidate in
                                    Button("Link \(candidate.family.rawValue) batch \(candidate.historyID.uuidString.prefix(8))") {link(candidate.link())}
                                }
                                ForEach(project.batchLinks) {item in Text("\(item.family.rawValue) history \(item.historyID.uuidString)").textSelection(.enabled)}
                            }
                            DisclosureGroup("Project revision history") {
                                ForEach(project.history.reversed()) {event in Text("Revision \(event.revision) · \(event.date.formatted()) · \(event.action)")}
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                } else {Text("Choose or create a project.").frame(maxWidth:.infinity,maxHeight:.infinity)}
            }
            .disabled(portablePreview != nil)
            DisclosureGroup("Unreferenced retained copies (\(session.unreferenced.count))") {
                ForEach(session.unreferenced,id:\.self) {id in
                    HStack {Text(id.uuidString);Button("Export") {export(id)};Button("Move Copy to Trash…") {orphanRemoval=id}}
                }
                if let issue=session.retentionIssue {Text(issue).foregroundStyle(.secondary)}
            }
            .disabled(portablePreview != nil)
            Text("Capacity: 64 projects, 128 retained archives / 256 MiB. Nothing is evicted. Unpin before removing a baseline; remove membership before deleting a retained copy. Project metadata export contains references and notes, not evidence bytes.").foregroundStyle(.secondary)
            Text(status).foregroundStyle(.secondary)
            HStack {Spacer();Button("Done",action:close).keyboardShortcut(.cancelAction)}
        }.padding(24).frame(minWidth:1000,idealWidth:1200,minHeight:650,idealHeight:800).disabled(busy)
        .onChange(of:storePath) {_,_ in name=session.project?.name ?? "";noteText="";acknowledged=false}
        .onChange(of:session.project?.id) {_,_ in name=session.project?.name ?? "";noteText="";acknowledged=false}
        .confirmationDialog("Remove evidence membership?",isPresented:Binding(get:{removal != nil},set:{if !$0 {removal=nil}})) {
            Button("Remove from Project",role:.destructive) {if let id=removal {remove(id)};removal=nil}
        } message:{Text("The retained archive remains until its unreferenced copy is explicitly moved to Trash.")}
        .confirmationDialog("Move unreferenced retained copy to Trash?",isPresented:Binding(get:{orphanRemoval != nil},set:{if !$0 {orphanRemoval=nil}})) {
            Button("Move Copy to Trash",role:.destructive) {if let id=orphanRemoval {removeUnreferenced(id)};orphanRemoval=nil}
        }
        .confirmationDialog("Move project metadata to Trash?",isPresented:Binding(get:{projectRemoval != nil},set:{if !$0 {projectRemoval=nil}})) {
            Button("Move Project to Trash",role:.destructive) {if let id=projectRemoval {removeProject(id)};projectRemoval=nil}
        } message:{Text("Original evidence archives remain retained. Other projects are unchanged.")}
    }
}
private struct ProjectEvidenceRow:View {
    let entry:ProjectEvidenceReference
    let pinned:Bool
    let issue:String?
    let pin:()->Void
    let review:()->Void
    let export:()->Void
    let remove:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            Text((pinned ? "Pinned baseline · " : "")+entry.kinds.joined(separator:", ")).font(.headline)
            Text("Evidence \(entry.id.uuidString) · SHA256 \(entry.digest)").textSelection(.enabled)
            Text("Added to project: \(entry.savedAt.formatted())")
            Text("Recorded extraction/check times: "+(entry.extractionTimes.isEmpty ? "unavailable" : entry.extractionTimes.map{$0.formatted()}.joined(separator:", ")))
            Text("Model/extractor: "+(entry.producerModels.isEmpty ? "not recorded" : entry.producerModels.joined(separator:", ")))
            Text("App version declarations: "+(entry.appVersions.isEmpty ? "not recorded" : entry.appVersions.joined(separator:", ")))
            if let issue {Text("Unavailable evidence: "+issue).foregroundStyle(.secondary)}
            HStack {
                Button(pinned ? "Unpin" : "Pin Baseline",action:pin).disabled(!pinned && issue != nil)
                Button("Review Evidence",action:review).disabled(issue != nil)
                Button("Export Original Archive…",action:export).disabled(issue != nil)
                Button("Remove Membership…",action:remove).disabled(pinned)
            }
        }
    }
}
