import Foundation

/// Optional display metadata, not code identity, signing assurance or report content.
public struct AppIdentity: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let version: String?
    public let build: String?
    public static let maximumFieldBytes = 256

    public init(infoPlist: [String: Any]) {
        func field(_ key: String) -> String? {
            guard let value = infoPlist[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= Self.maximumFieldBytes else { return nil }
            return value
        }
        bundleIdentifier = field("CFBundleIdentifier")
        version = field("CFBundleShortVersionString")
        build = field("CFBundleVersion")
    }
}
