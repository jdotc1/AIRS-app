import Foundation
import EntitlementDiffCore

public enum ComparisonSide: String, Sendable, CaseIterable {
    case previous, current
    public var label: String { rawValue.capitalized }
}

public enum InputState: Sendable {
    case empty
    case loading(sourceName: String)
    case ready(EntitlementSnapshot)
    case failed(sourceName: String, message: String)

    public var snapshot: EntitlementSnapshot? {
        if case .ready(let snapshot) = self { return snapshot }
        return nil
    }
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
    public var sourceName: String? {
        switch self {
        case .empty: nil
        case .loading(let name), .failed(let name, _): name
        case .ready(let snapshot): snapshot.sourceName
        }
    }
    public var errorMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}
