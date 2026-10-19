import SwiftUI
import EntitlementDiffCore

struct EntitlementBatchManifestReviewView: View {
    let review: EntitlementBatchManifestReview
    let adopt: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppDialogTitle(title: "Review Batch Manifest")
            Divider()
            Text(DisplayText.escaped(review.sourceURL.lastPathComponent)).textSelection(.enabled)
            Text("\(review.pairs.count) ordered pairs. Paths and architectures are selections only; app existence and contents have not been checked. Duplicate pairs remain visible and will be skipped by the existing runner.")
                .foregroundStyle(.secondary)
            if review.usesRelativePaths {
                Text("Relative paths are resolved from this manifest’s folder. Review the full paths below before adopting the plan.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                // The plan is bounded to 16 pairs. Eager rows avoid a lazy-layout
                // preference cycle while AppKit measures the sheet's minimum size.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.pairs) { pair in
                        VStack(alignment: .leading, spacing: 8) {
                            EntitlementBatchPairLabel(pair: pair)
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(review.replacedPairCount == 0 ? "Adopt this plan into an empty queue. Running it is a separate action." :
                 "This will replace \(review.replacedPairCount) queued pairs. The primary comparison, saved reports and recovery checkpoints remain unchanged.")
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(review.replacedPairCount == 0 ? "Use Manifest Selections" : "Replace Queue with Manifest", action: adopt)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(AppDesign.Space.page).frame(minWidth: 700, idealWidth: 780, minHeight: 460, idealHeight: 580)
        .appDialogSurface()
    }
}
