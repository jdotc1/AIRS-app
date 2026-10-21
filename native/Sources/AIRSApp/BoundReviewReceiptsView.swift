import SwiftUI
import AIRSEntitlements

struct BoundReviewReceiptsView: View {
    let entries: [BoundReviewReceiptEntry]
    let close: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Consumer Acknowledgments").font(.title2).bold()
            Text("Imported consumer claims. Correlation binds a receipt to an exact retained request; it does not establish issuer authenticity or verify recovery semantics.")
                .foregroundStyle(.secondary)
            if entries.isEmpty { Text("No consumer acknowledgments retained.") }
            List(entries) { entry in
                DisclosureGroup {
                    Text(String(decoding:entry.acknowledgment.bytes,as:UTF8.self))
                        .font(.system(.body,design:.monospaced)).textSelection(.enabled)
                } label: {
                    VStack(alignment:.leading,spacing:4) {
                        Text(entry.acknowledgment.outcome.capitalized+" · "+entry.acknowledgment.code)
                        Text(entry.associated ? "Associated with exact retained request" : "Unassociated — no exact retained request match")
                            .foregroundStyle(.secondary)
                        Text(entry.id.uuidString).font(.caption).textSelection(.enabled)
                    }
                }
            }
            HStack { Spacer(); Button("Done",action:close).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(minWidth:640,minHeight:420)
    }
}
