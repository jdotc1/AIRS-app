import AppKit
import Foundation
import SwiftUI

/// Explicit opt-in inspection of the real Settings scene, with no production stores.
struct SettingsReviewConfiguration {
    static var reviewParent: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer/Codex", isDirectory: true)
    }

    let root: URL
    let suite: String

    static func parse(environment: [String: String], bundleIdentifier: String?) throws -> Self? {
        let keys = ["AIRS_SETTINGS_REVIEW", "AIRS_SETTINGS_REVIEW_ROOT", "AIRS_SETTINGS_REVIEW_SUITE"]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        guard environment[keys[0]] == "1", let path = environment[keys[1]],
              let suite = environment[keys[2]], path.hasPrefix("/") else {
            throw ReviewError.invalidConfiguration
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let prefix = "AIRS-settings-visual-"
        guard root.deletingLastPathComponent().path == reviewParent.standardizedFileURL.path,
              root.lastPathComponent.hasPrefix(prefix),
              let id = UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))),
              suite == "dev.airs.settings-review.\(id.uuidString.lowercased()).preferences",
              bundleIdentifier == "dev.airs.settings-review.\(id.uuidString.lowercased())",
              root.resolvingSymlinksInPath().path == root.path else {
            throw ReviewError.invalidConfiguration
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw ReviewError.invalidConfiguration
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
            throw ReviewError.invalidConfiguration
        }
        return Self(root: root, suite: suite)
    }

    func preferences() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suite),
              UserDefaults(suiteName: suite + ".lumen") != nil else { throw ReviewError.preferencesUnavailable }
        guard defaults.persistentDomain(forName: suite)?.isEmpty != false,
              UserDefaults(suiteName: suite + ".lumen")?.persistentDomain(forName: suite + ".lumen")?.isEmpty != false else {
            throw ReviewError.preferencesNotFresh
        }
        return defaults
    }

    enum ReviewError: Error { case invalidConfiguration, preferencesUnavailable, preferencesNotFresh }
}

@MainActor
struct SettingsReviewRecents: WorkspaceRecentsRecording {
    var recentDocumentURLs: [URL] { [] }
    func noteRecentDocument(_ url: URL) {}
    func clearRecentDocuments() {}
}

/// Opens the actual Settings scene through SwiftUI; no GUI automation or picker.
struct SettingsReviewLauncher: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .task {
                NSApplication.shared.setActivationPolicy(.regular)
                openSettings()
                dismissWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
