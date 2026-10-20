import SwiftUI
import AIRSEntitlements

struct InspectionReviewView: View {
    let context: InspectionCaptureContext
    let adopt: (InspectionReviewAction) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Saved Inspection").font(.title2.bold())
            Text(context.label ?? context.document.snapshot.sourceName).font(.headline)
            Text("Captured: \(context.document.capturedAt.formatted())")
            Text("Architecture: \(context.document.snapshot.architecture.rawValue)")
            Text("Recorded identifier: \(context.document.identity?.bundleIdentifier ?? "unavailable")")
            Text("Recorded version/build: \(context.document.identity?.version ?? "unavailable") / \(context.document.identity?.build ?? "unavailable")")
            Text("Recorded origin: \(context.document.captureProvenance.rawValue)")
            Text("Scope: main executable, requested architecture. No original binary retained. Signature validation and Gatekeeper assessment were not performed. Recorded metadata is unverified.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Inspect") { adopt(.inspect) }
                Button("Use as Previous") { adopt(.useAsPrevious) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560).textSelection(.enabled)
    }
}
