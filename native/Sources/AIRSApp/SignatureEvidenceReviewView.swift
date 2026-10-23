import Foundation
import SwiftUI
import AIRSCore
import AIRSEntitlements

/// Saved evidence carries no live discovery capability and cannot authorize a read.
struct SignatureEvidenceReviewSession: Identifiable, Sendable {
    let id = UUID()
    let document: CodeSignatureEvidenceDocument
    let archiveBytes: Data
    let sourceURL: URL
}

struct SignatureEvidenceReviewView: View {
    let session: SignatureEvidenceReviewSession
    let busy: Bool
    let status: String
    let export: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signature Evidence").font(.title2.bold())
            ScrollView {
                SignatureEvidenceContent(document: session.document, historical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(status).foregroundStyle(.secondary)
            HStack {
                Button("Export Complete Archive…", action: export)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.disabled(busy)
        }.padding(24).frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 720)
    }
}

struct SignatureEvidenceContent: View {
    let document: CodeSignatureEvidenceDocument
    let historical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document.evidence.componentRelativePath).font(.headline)
            Text(historical
                ? "Historical byte evidence. The original file was not read or authenticated in this session."
                : "Bytes captured for this component. Later file changes do not update this record.")
            Text("Captured: \(document.capturedAt.formatted()) · Producer: \(document.producerVersion)")
            Text("Container: \(document.evidence.containerByteCount) bytes")
            Text("Container SHA256: " + document.evidence.containerSHA256).font(.caption.monospaced())
            Text("Structural evidence only. Signature validity, Gatekeeper policy and effective permissions were not evaluated. XML and DER payloads are retained without semantic decoding or comparison to Security.framework values.")
                .foregroundStyle(.secondary)
            ForEach(document.evidence.slices, id: \.index) { slice in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Slice \(slice.index) · \(stateLabel(slice.state))").font(.headline)
                    Text("CPU \(hex(slice.cpuType)) · raw subtype \(hex(slice.cpuSubtype))")
                    Text("Container offset \(slice.sliceOffset) · slice size \(slice.sliceSize) bytes")
                    Text("Slice SHA256: " + slice.sliceSHA256).font(.caption.monospaced())
                    Text(slice.diagnostic).foregroundStyle(.secondary)
                    if let offset = slice.signatureOffset, let count = slice.signatureByteCount {
                        Text("Signature: container offset \(offset) · \(count) bytes")
                    }
                    if let digest = slice.signatureSHA256 { Text("Signature SHA256: " + digest).font(.caption.monospaced()) }
                    ForEach(slice.slots, id: \.type) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(slot.type == 5 ? "XML entitlement blob" : "DER entitlement blob").bold()
                            Text("Slot \(slot.type) · magic \(hex(slot.magic)) · \(slot.byteCount) bytes")
                            Text("Container offset \(slot.containerOffset) · slice-relative offset \(slot.sliceRelativeOffset)")
                            Text("SHA256: " + slot.sha256).font(.caption.monospaced())
                            Text("Raw prefix, including the 8-byte blob header:").font(.caption)
                            Text(slot.bytes.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " "))
                                .font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                            if slot.bytes.count > 64 { Text("First 64 bytes shown; the complete retained blob is in the exported archive.").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.leading, 12)
                    }
                }.padding(.vertical, 8)
                Divider()
            }
            Text("Offsets are file byte positions; no runtime address or unwind verdict is inferred. Apple Silicon slices are examined structurally; other CPU families remain unexamined.")
                .foregroundStyle(.secondary)
        }.textSelection(.enabled)
    }

    private func hex(_ value: UInt32) -> String { "0x" + String(value, radix: 16) }
    private func stateLabel(_ state: CodeSignatureEvidenceState) -> String {
        switch state {
        case .collected: "Entitlement blobs collected"
        case .signatureAbsent: "No signature command"
        case .entitlementsAbsent: "Parsed signature; no entitlement slots"
        case .unexamined: "Unexamined"
        case .malformed: "Malformed signature metadata"
        case .budgetExceeded: "Capture limit reached"
        }
    }
}
