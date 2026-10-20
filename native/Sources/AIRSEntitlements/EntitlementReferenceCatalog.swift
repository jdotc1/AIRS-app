import Foundation

public struct EntitlementReference: Sendable {
    public let key: String
    public let explanation: String
    public let scopeNote: String
    public let sourceURL: URL
    public let reviewedDate: String
}

public enum EntitlementReferenceCatalog {
    public static func reference(forExactKey key: String) -> EntitlementReference? {
        references[Data(key.utf8)]
    }
    private static let references: [Data: EntitlementReference] = {
        let scope = "This is a recorded declaration, not observed app behavior, effective TCC permission, signature validity, or a safety assessment. Inspect the actual typed value."
        let descriptions = [
            ("com.apple.security.app-sandbox", "Declares use of the macOS App Sandbox containment model. The expected value is Boolean."),
            ("com.apple.security.network.client", "Declares outgoing connection capability for a sandboxed app. For TCP this concerns connection initiation; UDP has separate data-flow restrictions. The expected value is Boolean."),
            ("com.apple.security.network.server", "Declares incoming connection capability for a sandboxed app. For TCP this concerns accepting connections; UDP has separate data-flow restrictions. The expected value is Boolean.")
        ]
        return Dictionary(uniqueKeysWithValues: descriptions.compactMap { key, explanation in
            guard let url = URL(string: "https://developer.apple.com/documentation/bundleresources/entitlements/" + key) else { return nil }
            return (Data(key.utf8), EntitlementReference(key: key, explanation: explanation,
                scopeNote: scope, sourceURL: url, reviewedDate: "2026-10-20"))
        })
    }()
}
