import SwiftUI
import LumenUI
import AIRSCore

struct ReportOverviewView: View {
    let report: AuditReport
    let sourceLabel: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(report.image.displayName).font(AppDesign.Layout.pageTitle)
                        .textSelection(.enabled)
                    Text("\(sourceLabel) · \(report.image.architecture)")
                        .foregroundStyle(.secondary)
                }
                SectionCard("Analysis scope") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        StatTile(value: report.summary.functionCount, title: "Functions in this report")
                        StatTile(value: report.summary.agreementCount, title: "Agreement within scope", tint: .indigo)
                        StatTile(value: report.summary.inconsistencyCount, title: "Supported inconsistencies", tint: .orange)
                        StatTile(value: report.summary.unresolvedCount, title: "Unresolved functions")
                        StatTile(value: report.summary.metadataEntryCount, title: "Metadata entries")
                        StatTile(value: report.summary.checkedPCCount, title: "Modeled PC observations")
                    }
                    Text("Counts describe this report’s bounded model. Select a function to inspect its verdict, coverage, observation scope, and evidence.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SectionCard("Image identity") {
                    FactRow(label: "Architecture", value: report.image.architecture)
                    FactRow(label: "CPU subtype", value: String(report.image.cpuSubtype))
                    FactRow(label: "File type", value: report.image.fileType)
                    FactRow(label: "Preferred base", value: report.image.preferredBase, monospaced: true)
                    FactRow(label: "Slice extent", value: "\(report.image.sliceOffset) + \(report.image.sliceSize) bytes")
                    if let uuid = report.image.uuid { FactRow(label: "Image UUID", value: uuid, monospaced: true) }
                    FactRow(label: "Slice SHA-256", value: report.image.sliceSHA256, monospaced: true)
                    FactRow(label: "Container SHA-256", value: report.image.containerSHA256, monospaced: true)
                    if let path = report.image.path { FactRow(label: "Recorded path", value: path, monospaced: true) }
                }
                if let symbols = report.sourceAnnotations {
                    SourceAttachmentView(annotations: symbols)
                }
                if !report.issues.isEmpty {
                    SectionCard("Input and metadata issues") {
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.code).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                LumenBanner(issue.message, tone: .warning, spokenPrefix: "Issue").textSelection(.enabled)
                                if let offset = issue.offset {
                                    Text("File offset: \(offset) bytes")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                LimitationsView(title: "Report limitations", limitations: report.limitations)
                SectionCard("Metadata ranges") {
                    Text("Preferred VM address ranges; a metadata range can cover several functions.")
                        .font(.callout).foregroundStyle(.secondary)
                    if report.metadataRanges.isEmpty {
                        Text("No compact-unwind ranges were reported.").foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(report.metadataRanges.prefix(200).enumerated()), id: \.offset) { _, range in
                                HStack(alignment: .top, spacing: 14) {
                                    Text("\(range.start)–\(range.end)")
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer(minLength: 10)
                                    Text(range.encoding).font(.system(.caption, design: .monospaced))
                                    Text(readableToken(range.mode)).font(.caption)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        if report.metadataRanges.count > 200 {
                            Text("Showing the first 200 of \(report.metadataRanges.count) ranges. Export JSON to inspect every range.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                SectionCard("Analysis model") {
                    FactRow(label: "Generator", value: "\(report.generator.name) \(report.generator.version)")
                    FactRow(label: "Model version", value: report.generator.analysisModelVersion, monospaced: true)
                    FactRow(label: "Report schema", value: String(report.schemaVersion))
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Report overview")
    }
}

struct FindingDetailView: View {
    let report: AuditReport
    let finding: Finding
    let isBusy: Bool
    let exportHandoff: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(finding.displayName)
                        .font(.system(.title, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    VerdictLabel(verdict: finding.verdict)
                    Text(finding.verdict.explanation).foregroundStyle(.secondary)
                }
                SectionCard("Coverage and scope") {
                    FactRow(label: "Verdict", value: finding.verdict.title)
                    FactRow(label: "Coverage", value: readableToken(finding.coverage))
                    FactRow(label: "Observation scope", value: readableToken(finding.scope))
                    FactRow(label: "Unwind mode", value: readableToken(finding.mode))
                    if let encoding = finding.encoding {
                        FactRow(label: "Encoding", value: encoding, monospaced: true)
                    }
                    FactRow(label: "Instruction count", value: finding.instructionCount.formatted())
                    FactRow(label: "Checked PCs", value: finding.checkedPCs.isEmpty
                            ? "No supported observation reported"
                            : finding.checkedPCs.joined(separator: ", "), monospaced: !finding.checkedPCs.isEmpty)
                    if finding.scope == "modeled_leaf_body" {
                        Text("This comparison describes a modeled leaf-body state. It does not establish asynchronous unwind validity or coverage of the prologue and epilogue.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !finding.reasonCodes.isEmpty {
                    SectionCard("Reason codes") {
                        Text(finding.reasonCodes.joined(separator: "\n"))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                SectionCard("Evidence") {
                    if finding.evidence.isEmpty {
                        Text("No evidence rows were reported for this function.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(finding.evidence.enumerated()), id: \.offset) { index, evidence in
                            if index > 0 { Divider() }
                            EvidenceView(evidence: evidence)
                        }
                    }
                }
                SectionCard("Function range") {
                    FactRow(label: "Preferred VM", value: "\(finding.function.address)–\(finding.function.endAddress)", monospaced: true)
                    FactRow(label: "Image offset", value: finding.function.imageOffset, monospaced: true)
                    FactRow(label: "Size", value: "\(finding.function.size) bytes")
                    FactRow(label: "Boundary source", value: readableToken(finding.function.boundarySource))
                    FactRow(label: "Finding ID", value: finding.id, monospaced: true)
                }
                if let symbols = report.sourceAnnotations {
                    FindingSourceView(annotations: symbols, findingID: finding.id)
                }
                LimitationsView(title: "Function limitations", limitations: finding.limitations)
                LimitationsView(title: "Report limitations", limitations: report.limitations)
                SectionCard("Export a handoff") {
                    Text("Create versioned JSON containing the image identity, function range, and selected evidence for a proposed MacScope adapter.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(action: exportHandoff) {
                        Label("Export Handoff JSON…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isBusy)
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(finding.displayName)
    }
}

struct EvidenceView: View {
    let evidence: Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(evidence.code).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if let address = evidence.address {
                    Text("PC \(address)").font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(evidence.message).textSelection(.enabled)
            if evidence.expected != nil || evidence.observed != nil {
                HStack(alignment: .top, spacing: 12) {
                    EvidenceValueView(title: "Expected", value: evidence.expected?.displayText ?? "Not reported")
                    EvidenceValueView(title: "Observed", value: evidence.observed?.displayText ?? "Not reported")
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct EvidenceValueView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LimitationsView: View {
    let title: String
    let limitations: [String]

    var body: some View {
        SectionCard(title) {
            if limitations.isEmpty {
                Text("No additional limitations are listed at this level.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(limitations.enumerated()), id: \.offset) { _, limitation in
                    Label {
                        Text(limitation).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
