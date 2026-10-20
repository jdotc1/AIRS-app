import SwiftUI
import AIRSEntitlements

struct PolicyReviewSession:Identifiable,Sendable {
    let id=UUID()
    let prepared:PreparedPolicyReview
    var result:PolicyResult?
}
struct PolicyReviewView:View {
    let session:PolicyReviewSession
    let busy:Bool
    let status:String
    let evaluate:()->Void
    let export:()->Void
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Owned-build Policy Review").font(.title2).bold()
            Text("Mode: "+session.prepared.context.mode.rawValue).bold()
            Text("This request reads saved reports only. No app, signing or symbol checks are performed. Imported evidence cannot satisfy fresh requirements. A historical pass describes recorded expectations, not current trust or safety.")
            Text("Evaluation: "+session.prepared.context.id.uuidString).textSelection(.enabled)
            Text("Review identity: "+session.prepared.context.reviewDigest).textSelection(.enabled)
            Text("Required rules: \(session.prepared.policy.rules.count) · Exact-change acknowledgments: \(session.prepared.policy.acknowledgements.count)")
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if let result=session.result {
                        Text("Policy "+result.status.rawValue).font(.headline)
                        Text("Known violations: \(result.violations.count) · Missing evidence: \(result.missingEvidence.count)")
                        Text("Violations\n"+result.violations.joined(separator:"\n")).textSelection(.enabled)
                        Text("Missing evidence\n"+result.missingEvidence.joined(separator:"\n")).textSelection(.enabled)
                    } else {Text("Review the explicit mode, then evaluate this request. Missing evidence takes precedence; known violations remain visible.")}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            Text(status).foregroundStyle(.secondary)
            HStack {
                Button("Evaluate Recorded Evidence",action:evaluate).disabled(busy || session.result != nil)
                Button("Export Policy JSON…",action:export).disabled(busy || session.result == nil)
                Spacer();Button("Done",action:close).keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(minWidth:760,idealWidth:940,minHeight:520,idealHeight:640)
    }
}
