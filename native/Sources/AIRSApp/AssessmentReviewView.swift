import SwiftUI
import Foundation
import AIRSCore
import AIRSEntitlements

struct AssessmentReviewSession: Identifiable, Sendable {
    let id:UUID
    let document:AssessmentDocument
    let archiveBytes:Data
    let sourceURLs:[URL]
    let identity:AssessmentContentIdentity?
    let identityIssue:String?
    let evaluationID:UUID?
    init(id:UUID=UUID(),document:AssessmentDocument,archiveBytes:Data,sourceURLs:[URL],identity:AssessmentContentIdentity?=nil,identityIssue:String?=nil,evaluationID:UUID?=nil) {
        self.id=id;self.document=document;self.archiveBytes=archiveBytes;self.sourceURLs=sourceURLs
        self.identity=identity;self.identityIssue=identityIssue;self.evaluationID=evaluationID
    }
    static func capture(_ url:URL) throws -> Self {
        var identity:AssessmentContentIdentity?, issue:String?
        do {identity=try AssessmentContentIdentity.capture(url)} catch {if error is CancellationError {throw error};issue=error.localizedDescription}
        let inventory=try ComponentInventoryBuilder().build(url)
        let bytes=try ComponentInventoryDocumentCodec.encode(inventory)
        do {try identity?.validate()} catch {identity=nil;issue=error.localizedDescription}
        let document=try AssessmentDocument(subjectDocument:bytes,results:[])
        return try .init(document:document,archiveBytes:document.archive(),sourceURLs:[url],identity:identity,identityIssue:issue,evaluationID:UUID())
    }
    func adding(_ result:AssessmentEvidence) throws -> Self {
        let updated=try AssessmentDocument(subjectDocument:document.subjectDocument,results:document.results+[result])
        return try .init(id:id,document:updated,archiveBytes:updated.archive(),sourceURLs:sourceURLs,identity:identity,identityIssue:identityIssue,evaluationID:evaluationID)
    }
}
struct AssessmentReviewView: View {
    let session:AssessmentReviewSession
    let busy:Bool
    let status:String
    let run:(AssessmentKind)->Void
    let cancel:()->Void
    let export:()->Void
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Scoped App Assessments").font(.title2).bold()
            Text(session.evaluationID == nil ? "Imported historical evidence. Recorded passes do not establish current validation." : "Live selected app. Each assessment is separate and runs only when requested.")
            Text("Subject document SHA256: "+AssessmentDocument.digest(session.document.subjectDocument)).textSelection(.enabled)
            if let identity=session.identity {
                Text("Content SHA256: "+identity.digest).textSelection(.enabled)
                Text("Bounded physical app tree: regular file bytes, paths, modes/ownership/flags and extended attributes. No links/special files; 256 MiB, 4,096 entries, depth 32. Identity reuse checks observable changes; this is not an atomic snapshot.")
            }
            if let issue=session.identityIssue {Text("Current content binding unavailable: "+issue).foregroundStyle(.secondary)}
            Text("Static validation does not request network access. Local distribution assessment may contact system services/network and reflects this Mac’s current policy. Neither operation launches the selected app or changes OS security settings.")
            List(AssessmentKind.allCases,id:\.self) { kind in
                AssessmentResultRow(kind:kind,result:session.document.results.last{$0.kind == kind},historical:session.evaluationID == nil,
                    canRun:session.identity != nil && !busy && session.document.results.count < 64 && !session.document.results.contains(where:{$0.kind == kind}),run:{run(kind)})
            }
            Text(status).foregroundStyle(.secondary)
            HStack {
                Button("Export Complete Archive…",action:export).disabled(busy)
                if busy {Button("Cancel",action:cancel)}
                Spacer(); Button("Done",action:close).disabled(busy).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth:800,idealWidth:1000,minHeight:620,idealHeight:760)
    }
}
private struct AssessmentResultRow:View {
    let kind:AssessmentKind
    let result:AssessmentEvidence?
    let historical:Bool
    let canRun:Bool
    let run:()->Void
    private var title:String {switch kind {case .signingInformation:"Extract Signing Metadata";case .signatureValidity:"Validate Static Signature";case .localDistribution:"Assess Local Distribution (May Use Network)"}}
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            Text(kind.rawValue+": "+(result?.outcome.rawValue ?? AssessmentOutcome.notPerformed.rawValue)).font(.headline)
            Text(NativeAssessmentChecker.description(kind).2)
            if let result {
                Text(historical ? "Historical record; current validation not performed." : "Recorded in this review; applies only to its recorded content and scope.")
                Text("Started: \(result.startedAt.formatted()) · Completed: \(result.completedAt.formatted())")
                Text("Host: "+result.hostOS+" · API/tool: "+result.toolOrAPI)
                Text("Flags: "+result.argumentsOrFlags.joined(separator:" "))
                Text("Component: "+result.componentRelativePath+" · Architecture: "+(result.architecture ?? "See operation scope"))
                Text(result.scopeDescription)
                Text("Scoped content SHA256: "+(result.subjectFileDigest ?? "unavailable"))
                Text(result.diagnostic).textSelection(.enabled)
            }
            Button(title,action:run).disabled(!canRun)
        }.padding(.vertical,8)
    }
}
