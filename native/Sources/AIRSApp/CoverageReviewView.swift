import SwiftUI
import AIRSEntitlements

struct CoverageReviewSession:Identifiable,Sendable {
    let id=UUID()
    let inventory:CoverageInventory
    let sourceURL:URL
}
struct CoverageReviewView:View {
    let inventory:CoverageInventory
    let busy:Bool
    let status:String
    let openObservation:(CoverageInventory.Example,String)->Void
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Saved-report Coverage Inventory").font(.title2).bold()
            Text("Aggregation status: "+inventory.status+" · Supplied reports: \(inventory.summary.input_report_count) · Duplicate reports excluded: \(inventory.summary.duplicate_report_count)")
            Text("Supplied findings: \(inventory.summary.function_count) · Agreement: \(inventory.summary.agreement_count) · Inconsistency: \(inventory.summary.inconsistency_count) · Unresolved: \(inventory.summary.unresolved_count)")
            Text("Aggregation complete does not mean analysis complete. Input limits, partial reads and issues remain in each source report. These are verdict counts, separate from metadata coverage and observation scope; they are not real-world prevalence.").foregroundStyle(.secondary)
            if let ratio=inventory.compatibleVerdictRatio {
                Text("Resolved verdict count: \(ratio.resolvedNumerator) / \(ratio.functionDenominator) supplied functions in compatible reports. This is not all-PC or whole-binary unwind coverage.")
            } else {
                Text("No combined ratio: zero functions, unknown configuration, incompatible model/configuration/CPU scope, or conflicting reports.")
            }
            List {
                Section("Supplied report records") {
                    ForEach(inventory.reports) {record in
                        VStack(alignment:.leading,spacing:4) {
                            Text("Report \(record.index + 1) · "+record.image.display_name+" · "+record.model)
                            Text(inventory.configurationLabel(for:record)+" · "+record.image.architecture+" · "+record.image.slice_sha256).textSelection(.enabled)
                            Text("\(record.summary.unresolvedCount) unresolved / \(record.summary.functionCount) supplied functions · \(record.summary.checkedPCCount) checked PCs"+(record.duplicate_of.map{" · Duplicate of report \($0 + 1)"} ?? ""))
                        }
                    }
                }
                Section("Unresolved categories · counts overlap; at most eight examples per category") {
                    ForEach(inventory.reasons) {reason in
                        DisclosureGroup(reason.reason+" · \(reason.count) unresolved functions") {
                            ForEach(reason.examples) {example in
                                VStack(alignment:.leading,spacing:4) {
                                    Text("Report \(example.report_index + 1) · "+(example.function_name ?? example.finding_id)+" · "+example.pc)
                                    Text("Function-entry preferred VM · "+example.scope+" · "+example.mode)
                                    Button("Choose Saved Source Observation…") {openObservation(example,reason.reason)}.disabled(busy)
                                }
                            }
                        }
                    }
                }
            }
            Text("Select an original saved audit report to resolve a reference. Inventory files contain no source path, full observations or original-report byte digest; a match does not authenticate the original export.").foregroundStyle(.secondary)
            Text(status).foregroundStyle(.secondary)
            HStack {Spacer();Button("Done",action:close).keyboardShortcut(.cancelAction).disabled(busy)}
        }.padding(24).frame(minWidth:820,idealWidth:1040,minHeight:620,idealHeight:760)
    }
}
