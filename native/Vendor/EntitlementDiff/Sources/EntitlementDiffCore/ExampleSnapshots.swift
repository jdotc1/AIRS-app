import Foundation

/// Synthetic values demonstrate comparison states, not a recommended entitlement policy.
public enum ExampleSnapshots {
    public static func structuredPair(architecture: Architecture) -> (previous: EntitlementSnapshot, current: EntitlementSnapshot) {
        let old = EntitlementValue.dictionary(.init([
            "enabled": .boolean(true), "removed": .string("old"),
            "long-text": .string(String(repeating: "0123456789 ", count: 120) + "PREVIOUS END"),
            "samples": .array((0..<2_100).map { .integer(Int64($0)) }),
            "options": .dictionary(.init(["labels": .array([.string("local"), .string("research")])]))
        ]))
        let new = EntitlementValue.dictionary(.init([
            "enabled": .integer(1), "added": .unsignedInteger(UInt64.max),
            "long-text": .string(String(repeating: "0123456789 ", count: 120) + "CURRENT END"),
            "samples": .array((0..<2_100).map { .integer(Int64($0 == 75 ? 999 : $0)) }),
            "options": .dictionary(.init(["labels": .array([.string("research"), .string("local"), .string("new")])]))
        ]))
        func snapshot(_ value: EntitlementValue, _ name: String) -> EntitlementSnapshot {
            .init(sourceName: name, signingIdentifier: "org.example.EntitlementDiffFixture", architecture: architecture,
                  origin: .syntheticExample, entitlements: .init(["example.structured-value": value]))
        }
        return (snapshot(old, "Structured-Before.app"), snapshot(new, "Structured-After.app"))
    }

    public static func pair(architecture: Architecture) -> (previous: EntitlementSnapshot, current: EntitlementSnapshot) {
        let previous = EntitlementDictionary([
            "com.apple.security.app-sandbox": .boolean(true),
            "com.apple.security.network.client": .boolean(true),
            "com.apple.security.get-task-allow": .boolean(true),
            "example.feature-labels": .array([.string("research"), .string("local")]),
            "example.parser-version": .integer(1)
        ])
        let current = EntitlementDictionary([
            "com.apple.security.app-sandbox": .boolean(true),
            "com.apple.security.network.client": .boolean(false),
            "com.apple.security.files.user-selected.read-only": .boolean(true),
            "example.feature-labels": .array([.string("local"), .string("research")]),
            "example.parser-version": .integer(2)
        ])
        return (
            .init(sourceName: "Example-Before.app", signingIdentifier: "org.example.EntitlementDiffFixture", architecture: architecture,
                  origin: .syntheticExample, entitlements: previous),
            .init(sourceName: "Example-After.app", signingIdentifier: "org.example.EntitlementDiffFixture", architecture: architecture,
                  origin: .syntheticExample, entitlements: current)
        )
    }
}
