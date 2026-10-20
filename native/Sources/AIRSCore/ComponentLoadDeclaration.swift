import Foundation
public struct ComponentLoadDeclaration: Codable, Sendable {
    public let architecture: String
    public let command: String
    public let path: String
    public let currentVersion: String?
    public let compatibilityVersion: String?
    public let useFlags: UInt32?
    public init(architecture: String, command: String, path: String, currentVersion: String? = nil, compatibilityVersion: String? = nil, useFlags: UInt32? = nil) {
        self.architecture = architecture; self.command = command; self.path = path
        self.currentVersion = currentVersion; self.compatibilityVersion = compatibilityVersion; self.useFlags = useFlags
    }
}
