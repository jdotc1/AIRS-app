import AppKit

// Reused from MacScope's WorkspaceRecents: keep the system list injectable.
@MainActor
protocol WorkspaceRecentsRecording {
    func noteRecentDocument(_ url: URL)
    var recentDocumentURLs: [URL] { get }
    func clearRecentDocuments()
}

@MainActor
struct SystemDocumentRecents: WorkspaceRecentsRecording {
    func noteRecentDocument(_ url: URL) { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    var recentDocumentURLs: [URL] { NSDocumentController.shared.recentDocumentURLs }
    func clearRecentDocuments() { NSDocumentController.shared.clearRecentDocuments(nil) }
}
