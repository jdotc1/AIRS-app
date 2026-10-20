import Foundation

enum AppIntakeRequest: Sendable {
    case inspect(URL)
    case compare(previous: URL, current: URL)
    case chooseTask(URL)
}

enum AppIntake {
    /// Classify only. Selection order is explicit, never inferred chronology.
    static func stage(_ urls: [URL]) throws -> AppIntakeRequest {
        guard (1...2).contains(urls.count), urls.allSatisfy({
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.pathExtension.lowercased() == "app"
        }) else { throw CocoaError(.fileReadUnsupportedScheme) }
        if urls.count == 1 { return .chooseTask(urls[0]) }
        guard urls[0].standardizedFileURL != urls[1].standardizedFileURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return .compare(previous: urls[0], current: urls[1])
    }
}

struct AppIntakeReview: Identifiable {
    let id = UUID()
    var request: AppIntakeRequest
    let auditRevision: UUID
    let entitlementRevision: UUID
}
