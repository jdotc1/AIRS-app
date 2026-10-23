import SwiftUI
import AIRSEntitlements

struct DecodeInventorySession: Identifiable, Sendable {
    let id = UUID()
    let inventory: DecodeInventory
    let sourceURL: URL
}

struct DecodeInventoryView: View {
    let inventory: DecodeInventory
    let busy: Bool
    let status: String
    let openAudit: (String) -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment:.leading, spacing:12) {
            Text("Saved Decoder Inventory").font(.title2).bold()
            Text(inventory.image.display_name + " · " + inventory.image.architecture + " · " + inventory.decoder_model)
            Text("Slice SHA-256: " + inventory.image.slice_sha256).textSelection(.enabled)
            Text("Recorded status: \(inventory.status) · Functions: \(inventory.summary.function_count) · Fully scanned: \(inventory.summary.fully_scanned_function_count)")
            Text("Observed words: \(inventory.summary.observed_word_count) · Decoder admitted: \(inventory.summary.decoder_admitted_word_count) · Refused: \(inventory.summary.decline_count) · Omitted refusal details: \(inventory.summary.omitted_decline_count)")
            Text("Saved decode observations only. Decoder admission does not establish supported effects, reachability, valid unwind rules or agreement. No image is read or analyzed when this file opens.").foregroundStyle(.secondary)
            DisclosureGroup("Recorded image identity and limits") {
                VStack(alignment:.leading) {
                    Text("Container SHA-256: " + inventory.image.container_sha256)
                    Text("Slice container offset \(inventory.image.slice_offset) · Size \(inventory.image.slice_size) · CPU subtype \(inventory.image.cpu_subtype)")
                    Text("UUID: " + (inventory.image.uuid ?? "not recorded") + " · Preferred base " + inventory.image.preferred_base)
                    ForEach(inventory.analysis_config.limits.keys.sorted(),id:\.self) { key in
                        Text(key + ": " + String(inventory.analysis_config.limits[key] ?? 0))
                    }
                }.textSelection(.enabled)
            }
            List {
                Section("Functions · addresses are preferred VM") {
                    ForEach(inventory.functions) { row in DecodeInventoryFunctionView(row:row,busy:busy,openAudit:openAudit) }
                }
                Section("Recorded refusal categories") {
                    ForEach(inventory.reasons) { reason in Text(reason.reason + " · \(reason.observed_count) observed words") }
                }
                Section("Recorded limitations") {
                    ForEach(Array(inventory.limitations.enumerated()),id:\.offset) { item in Text(item.element) }
                }
                Section("Recorded parser issues") {
                    ForEach(Array(inventory.issues.enumerated()),id:\.offset) { item in
                        Text(item.element.code + ": " + item.element.message)
                    }
                }
            }
            Text("Identity and counts are recorded claims from the selected file; import does not authenticate the original image. Complete means complete recorded scans and details, not unwind success.").foregroundStyle(.secondary)
            Text("Choose a saved audit for a function to review its independently recorded observations. Identity matching does not authenticate original bytes or equate decode and audit budgets.").foregroundStyle(.secondary)
            Text(status).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done",action:close).keyboardShortcut(.cancelAction).disabled(busy) }
        }.padding(24).frame(minWidth:820,idealWidth:1040,minHeight:620,idealHeight:760)
    }
}

private struct DecodeInventoryFunctionView: View {
    let row: DecodeInventory.Row
    let busy: Bool
    let openAudit: (String) -> Void
    var body: some View {
        DisclosureGroup((row.function.name ?? row.function.address) + " · " + row.scan_status + " · \(row.decline_count) refused words") {
            VStack(alignment:.leading,spacing:6) {
                Text(row.function.address + "–" + row.function.end_address + " · Image-relative offset " + row.function.image_offset).textSelection(.enabled)
                Text("Observed \(row.observed_word_count) words · Admitted \(row.decoder_admitted_word_count) · Omitted details \(row.omitted_decline_count)")
                Text("Word scan \(row.word_scan_complete ? "complete" : "incomplete") · Refusal details \(row.blockers_complete ? "complete" : "incomplete")")
                Button("Choose Saved Audit for This Function…") {openAudit(row.id)}
                    .disabled(busy || row.function.size <= 0 || row.scan_status == "invalid_extent")
                ForEach(row.blockers) { blocker in
                    Text(blocker.address + " · " + blocker.word + " · " + blocker.reason + ": " + blocker.message).textSelection(.enabled)
                }
            }
        }
    }
}
