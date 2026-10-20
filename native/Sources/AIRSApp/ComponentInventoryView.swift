import SwiftUI
import AIRSCore

struct ComponentInventoryReview: Identifiable {
    let id = UUID()
    let inventory: ComponentInventory
    let archiveBytes: Data
    let sourceURL: URL
    let imported: Bool
}
struct ComponentInventoryView: View {
    let review: ComponentInventoryReview
    let status: String
    let isWriting: Bool
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
                        ComponentInventoryRow(record: record)
                    }
                }
            }
            Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Export includes the complete original archive and all of its evidence records, regardless of filters.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Export Complete Archive…", action: export)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.disabled(isWriting)
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
