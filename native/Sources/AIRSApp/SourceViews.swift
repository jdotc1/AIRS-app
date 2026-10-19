import SwiftUI
import AIRSCore

struct SourceAttachmentView: View {
    let annotations: SourceAnnotations

    var body: some View {
        SectionCard("Source annotations") {
            FactRow(label: "Lookup status", value: readableToken(annotations.status))
            Text(annotations.message).textSelection(.enabled)
            if let attachment = annotations.attachment {
                FactRow(label: "dSYM UUID", value: attachment.uuid, monospaced: true)
                FactRow(label: "dSYM slice", value: "\(attachment.architecture) · subtype \(attachment.cpuSubtype)")
                FactRow(label: "Debug artifact", value: attachment.path, monospaced: true)
                FactRow(label: "Debug SHA-256", value: attachment.sliceSHA256, monospaced: true)
            }
            Text("Source labels do not change unwind findings or establish cross-build function identity. Inline chains are not evaluated.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct FindingSourceView: View {
    let annotations: SourceAnnotations
    let findingID: String

    var body: some View {
        SectionCard("Source location") {
            if let source = annotations.functions.first(where: { $0.findingID == findingID }) {
                FactRow(label: "Lookup status", value: readableToken(source.status))
                FactRow(label: "Preferred PC", value: source.pc, monospaced: true)
                if source.nameStatus == "duplicate" {
                    Text("This symbol name is duplicated. Lookup uses the finding’s preferred PC, not its name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(source.locations.enumerated()), id: \.offset) { _, location in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(location.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text(location.line == 0 ? "Line unspecified" : "Line \(location.line) · column \(location.column) · discriminator \(location.discriminator)")
                        Text(readableToken(location.sourceStatus)).foregroundStyle(.secondary)
                    }
                }
                if source.candidateCount > 1 {
                    Text("\(source.candidateCount) overlapping line candidates; no unique source location is established. Showing at most eight.")
                }
                if source.locations.isEmpty {
                    Text("No line-table interval covers this function-entry PC. No source location was inferred.")
                }
            } else {
                Text(annotations.message)
            }
            Text("DWARF line-table annotation only. Inline chains and unwind CFI are not evaluated. Available source contents have not been verified against the build.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
