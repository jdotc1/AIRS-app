import SwiftUI
import AIRSCore
import AIRSEntitlements

struct ComponentInventoryReview: Identifiable, Sendable {
    let id = UUID()
    let inventory: ComponentInventory
    private(set) var archiveBytes: Data
    let sourceURL: URL
    let imported: Bool
    let live: LiveComponentInventory?
    private(set) var signatureEvidence: [UUID: CodeSignatureEvidenceDocument] = [:]

    init(inventory: ComponentInventory, archiveBytes: Data, sourceURL: URL, imported: Bool,
         live: LiveComponentInventory? = nil) {
        self.inventory = inventory; self.archiveBytes = archiveBytes
        self.sourceURL = sourceURL; self.imported = imported
        self.live = imported ? nil : live
    }

    func canCaptureSignature(_ componentID: UUID) -> Bool {
        !imported && live?.inventory.id == inventory.id && live?.units[componentID] != nil
            && inventory.components.contains { $0.id == componentID } && signatureEvidence[componentID] == nil
    }

    mutating func addSignatureEvidence(_ document: CodeSignatureEvidenceDocument) throws {
        let componentID = document.evidence.componentID
        guard canCaptureSignature(componentID),
              let component = inventory.components.first(where: { $0.id == componentID }),
              component.relativePath.utf8.elementsEqual(document.evidence.componentRelativePath.utf8) else {
            throw InspectionArchiveError.invalid
        }
        let existing = try InspectionArchive.decode(archiveBytes)
        let addition = try InspectionArchive.decode(document.archive())
        guard addition.attachments.count == 1, let attachment = addition.attachments.first else {
            throw InspectionArchiveError.invalid
        }
        var references = existing.components.map { reference in
            reference.id == componentID
                ? ArchiveComponentReference(id: reference.id, evidenceIDs: reference.evidenceIDs + [attachment.id])
                : reference
        }
        if !references.contains(where: { $0.id == componentID }) {
            references.append(.init(id: componentID, evidenceIDs: [attachment.id]))
        }
        let merged = try InspectionArchive(attachments: existing.attachments + [attachment], components: references).encode()
        // Publish only after the complete combined archive passes its own budget.
        archiveBytes = merged
        signatureEvidence[componentID] = document
    }
}
struct ComponentInventoryView: View {
    let review: ComponentInventoryReview
    let status: String
    let isWriting: Bool
    let busy: Bool
    let captureSignature: (UUID) -> Void
    let cancel: () -> Void
    let export: () -> Void
    let close: () -> Void
    @State private var architecture = "All architectures"
    @State private var intelOnly = false
    private var visible: [ComponentRecord] {
        let records = intelOnly ? review.inventory.observedIntelOnly : review.inventory.components
        return architecture == "All architectures" ? records : records.filter { $0.architectures.contains(architecture) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Component Inventory").font(.title2).bold()
            Text(review.imported ? "Imported inventory: recorded declarations are unverified; no live app was read." : "Observed headers and declared bundle labels. No inspected app was executed.")
            Text("Architecture and minimum OS declarations do not prove compatibility, effective permissions, signature validity or supported unwind coverage.")
                .foregroundStyle(.secondary)
            HStack {
                Picker("Architecture", selection: $architecture) {
                    Text("All architectures").tag("All architectures")
                    ForEach(Array(Set(review.inventory.components.flatMap(\.architectures))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("Intel-only declarations", isOn: $intelOnly)
            }
            Text("Scope: \(review.inventory.scope.completion.rawValue) · \(visible.count) of \(review.inventory.components.count) records shown")
                .bold()
            List {
                Section("Scope and gaps") {
                    Text("Searched locations: " + review.inventory.scope.searchedLocations.joined(separator: ", "))
                    if !review.inventory.scope.issues.isEmpty { Text(review.inventory.scope.issues.joined(separator: "\n")) }
                    if !review.inventory.scope.exclusions.isEmpty { Text("Excluded:\n" + review.inventory.scope.exclusions.joined(separator: "\n")) }
                }
                Section("Component declarations") {
                    ForEach(visible) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            ComponentInventoryRow(record: record)
                            if let document = review.signatureEvidence[record.id] {
                                DisclosureGroup("Captured signature evidence") {
                                    SignatureEvidenceContent(document: document, historical: false)
                                }
                            } else if !review.imported {
                                Button("Capture Signature Evidence") { captureSignature(record.id) }
                                    .disabled(busy || !review.canCaptureSignature(record.id))
                            }
                        }
                    }
                }
            }
            Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Export includes the complete original archive and all of its evidence records, regardless of filters.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Export Complete Archive…", action: export).disabled(busy)
                if busy && !isWriting { Button("Cancel Capture", action: cancel) }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction).disabled(busy)
            }
        }.padding(24).frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 650)
    }
}
private struct ComponentInventoryRow: View {
    let record: ComponentRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.relativePath).font(.headline).textSelection(.enabled)
            Text("\(record.kind) · \(record.declaredBundleID ?? "Identifier unavailable") · \(record.declaredVersion ?? "Version unavailable")")
            Text("Architectures: " + (record.architectures.isEmpty ? "unavailable" : record.architectures.joined(separator: ", ")))
            Text("Declared minimum macOS: " + (record.minimumOSByArchitecture.isEmpty ? "unavailable" : record.minimumOSByArchitecture.keys.sorted().map { $0 + " " + (record.minimumOSByArchitecture[$0] ?? "unavailable") }.joined(separator: ", ")))
            if !record.readIssues.isEmpty { Text(record.readIssues.joined(separator: "\n")).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
}
