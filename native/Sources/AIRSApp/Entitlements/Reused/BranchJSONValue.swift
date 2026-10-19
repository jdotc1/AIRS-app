import Foundation
import EntitlementDiffCore

/// Complete captured container, independent of child paging and preview labels.
struct BranchJSONValue: Sendable {
    let value: EntitlementValue
    init?(_ value: EntitlementValue?) {
        guard let value else { return nil }
        switch value {
        case .array, .dictionary: self.value = value
        default: return nil
        }
    }
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
