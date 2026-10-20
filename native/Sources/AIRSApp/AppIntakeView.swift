import SwiftUI

struct AppIntakeView: View {
    let review: AppIntakeReview
    let inspect: () -> Void
    let unwind: () -> Void
    let swap: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Application Task").font(.title2.bold())
            switch review.request {
            case .chooseTask(let url), .inspect(let url):
                Text(url.path).textSelection(.enabled)
                Text("Read this application as data. The target is never launched.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Analyze Unwind", action: unwind)
                    Button("Inspect Declarations", action: inspect).keyboardShortcut(.defaultAction)
                }
            case .compare(let previous, let current):
                Text("Previous: \(previous.path)").textSelection(.enabled)
                Text("Current: \(current.path)").textSelection(.enabled)
                Text("Order follows your selection. Confirm the comparison direction.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Swap", action: swap)
                    Spacer()
                    Button("Compare Declarations", action: inspect).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 600)
    }
}
