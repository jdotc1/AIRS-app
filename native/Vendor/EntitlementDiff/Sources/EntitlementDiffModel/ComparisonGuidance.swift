/// Presentation for an incomplete comparison. Does not read inputs or create reports.
public struct ComparisonGuidance: Sendable {
    public enum Action: Hashable, Sendable {
        case choose(ComparisonSide), retry(ComparisonSide), openSavedReport, cancel

        public var label: String {
            switch self {
            case .choose(let side): "Choose \(side.label) App…"
            case .retry(let side): "Retry \(side.label) Inspection"
            case .openSavedReport: "Open Saved Report…"
            case .cancel: "Cancel and Clear"
            }
        }
    }

    public let title: String
    public let message: String
    public let actions: [Action]

    public init(previous: InputState, current: InputState,
                retryableSides: Set<ComparisonSide> = [], reportError: String? = nil) {
        let inputs: [(ComparisonSide, InputState)] = [(.previous, previous), (.current, current)]
        let loading = inputs.filter { $0.1.isLoading }.map { $0.0.label }
        let failed = inputs.filter { $0.1.errorMessage != nil }.map { $0.0 }
        if !loading.isEmpty {
            title = "Reading \(loading.joined(separator: " and ")) input…"
            message = "Waiting for inspection to finish. A comparison appears only when both inputs are ready."
            actions = [.cancel]
        } else if !failed.isEmpty {
            title = "\(failed.map(\.label).joined(separator: " and ")) inspection failed"
            message = "Retry the failed input or choose another app. Unreadable inputs do not become empty comparisons."
            actions = inputs.flatMap { side, state -> [Action] in
                if state.errorMessage != nil {
                    return (retryableSides.contains(side) ? [.retry(side)] : []) + [.choose(side)]
                }
                return state.isEmpty ? [.choose(side)] : []
            }
        } else if let reportError {
            title = "Comparison unavailable"
            message = reportError
            actions = [.choose(.previous), .choose(.current)]
        } else if previous.isEmpty && current.isEmpty {
            title = "Choose two app builds or open a saved report"
            message = "Compare Previous → Current using the selected architecture. Saved reports can supply a baseline or a complete comparison."
            actions = [.choose(.previous), .choose(.current), .openSavedReport]
        } else if current.isEmpty {
            title = previous.snapshot?.isSavedBaseline == true
                ? "Choose a Current app to compare with this saved baseline"
                : "Choose the Current app build"
            message = "Previous is ready. Choose Current to complete the comparison."
            actions = [.choose(.current)]
        } else if previous.isEmpty {
            title = "Choose the Previous app build"
            message = "Current is ready. Choose Previous to complete the comparison."
            actions = [.choose(.previous)]
        } else {
            title = "Preparing comparison…"
            message = "Both inputs are ready."
            actions = []
        }
    }
}
