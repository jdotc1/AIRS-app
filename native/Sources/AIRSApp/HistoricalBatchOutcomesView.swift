import Foundation
import SwiftUI
import AIRSEntitlements

/// Session-local presentation of one admitted historical snapshot, never a queue.
struct ImportedProjectHistorySnapshot:Sendable {
    let projectID:UUID
    let revision:Int
    let storeRoot:URL
    let history:PortableSettledBatchEvidence
    func matches(project:InspectionProject?,store:URL)->Bool {
        project?.id == projectID && project?.revision == revision
            && store.standardizedFileURL == storeRoot.standardizedFileURL
    }
}

struct HistoricalBatchOutcomesView:View {
    let history:PortableSettledBatchEvidence
    var body:some View {
        GroupBox("Imported historical batch outcomes") {
            VStack(alignment:.leading,spacing:8) {
                Text("\(history.outcomes.count) recorded associations · read-only snapshot")
                Text("These are imported recorded outcomes, not current queue state or permission to run work. Comparison reports are not transported. Audit histories remain unsupported. Recorded link/library identifiers do not authenticate original library provenance.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:10) {
                        ForEach(history.outcomes,id:\.link.id) {outcome in HistoricalBatchOutcomeView(outcome:outcome)}
                        if history.outcomes.isEmpty {Text("No historical batch associations in this snapshot.")}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:220)
            }.padding(6)
        }
    }
}

private struct HistoricalBatchOutcomeView:View {
    let outcome:PortableBatchOutcome
    var body:some View {
        DisclosureGroup(outcome.link.family.rawValue + " · recorded library ID " + outcome.link.historyID.uuidString) {
            VStack(alignment:.leading,spacing:6) {
                Text("Association " + outcome.link.id.uuidString).textSelection(.enabled)
                if let absence=outcome.absence {
                    Text("Outcome unavailable: " + absence.rawValue)
                } else {
                    Text("Result batch ID: " + (outcome.batchID?.uuidString ?? "not recorded"))
                    Text("Batch cancelled: " + (outcome.cancelled.map{$0 ? "yes":"no"} ?? "not recorded"))
                    if let date=outcome.finishedAt {Text("Recorded finish: " + date.formatted())}
                    ForEach(outcome.rows,id:\.id) {row in
                        VStack(alignment:.leading,spacing:4) {
                            Text(row.status.title + " · " + row.requestedArchitecture + " · " + row.message)
                            Text("Changed: " + (row.changedCount.map(String.init) ?? "not recorded") + " · Unchanged: " + (row.unchangedCount.map(String.init) ?? "not recorded"))
                            Text(row.reportIncluded ? "Report included" : "Comparison report not included").foregroundStyle(.secondary)
                        }
                    }
                }
            }.textSelection(.enabled)
        }
    }
}
