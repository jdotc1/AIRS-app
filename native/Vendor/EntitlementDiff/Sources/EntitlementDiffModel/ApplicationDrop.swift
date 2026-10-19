import Foundation

public enum ApplicationDropError: Error, LocalizedError, Sendable {
    case oneApplicationRequired
    case localApplicationRequired
    public var errorDescription: String? {
        switch self {
        case .oneApplicationRequired: "Drop one application onto the Previous or Current pane."
        case .localApplicationRequired: "Drop a local .app bundle. The selected architecture will be used; no application will be launched."
        }
    }
}

public enum ApplicationDrop {
    /// Only validates the drop envelope. Bundle and signing validation remain
    /// with the existing asynchronous reader, after scoped access is acquired.
    public static func applicationURL(from urls: [URL]) throws -> URL {
        guard urls.count == 1, let url = urls.first else { throw ApplicationDropError.oneApplicationRequired }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.pathExtension.lowercased() == "app" else { throw ApplicationDropError.localApplicationRequired }
        return url
    }
}
