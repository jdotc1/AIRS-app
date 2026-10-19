import SwiftUI
import EntitlementDiffCore

struct SavedBaselineView: View {
    let report: SavedReport
    let adopt: (EntitlementSnapshot) -> Void
    let openComparison: () -> Void
    let cancel: () -> Void
    @State private var useCurrent = false
    private var selected: EntitlementSnapshot { useCurrent ? report.current : report.previous }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppDialogTitle(title: "Open Saved Report")
            Divider()
            Text("Saved report — unverified metadata, not a fresh native inspection.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Saved pair: \(EntitlementValue.string(report.previous.sourceName).preview(maxCharacters: 128)) → \(EntitlementValue.string(report.current.sourceName).preview(maxCharacters: 128))")
                .font(.caption).textSelection(.enabled)
            Picker("Snapshot to use as Previous", selection: $useCurrent) {
                Text("Report Previous").tag(false)
                Text("Report Current").tag(true)
            }.pickerStyle(.segmented)
            Text(EntitlementValue.string(selected.sourceName).preview(maxCharacters: 256))
                .font(.headline).textSelection(.enabled)
            Text("Signing identifier: \(EntitlementValue.string(selected.signingIdentifier).preview(maxCharacters: 512))")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("Requested architecture: \(selected.architecture.rawValue) · \(selected.entitlements.entries.count) keys")
            if selected.origin == .syntheticExample { Text("This report claims synthetic example data.").foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true) }
            Text("Use as Previous replaces this session, clears Current and selects this architecture. Choose a Current app afterward. Open Saved Comparison instead opens both saved snapshots. Results are recomputed; no source paths are loaded or saved.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use as Previous") { adopt(selected) }.keyboardShortcut(.defaultAction)
                Button("Open Saved Comparison", action: openComparison)
            }
        }.padding(AppDesign.Space.page).frame(minWidth: 570, idealWidth: 640)
        .appDialogSurface()
    }
}
