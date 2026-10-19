import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import AIRSCore
import EntitlementDiffCore

/// Routing reads only the envelope; original bytes go to the existing validators.
enum AIRSOpenedReport: Sendable {
    case audit(AuditReport, Data)
    case entitlements(SavedReport)

    private struct Envelope: Decodable {
        enum Keys: String, CodingKey { case schema_version, report_kind, schemaVersion, tool }
        let kind: Kind
        enum Kind { case audit, entitlements }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            let audit = fields.contains(.schema_version) || fields.contains(.report_kind)
            let entitlements = fields.contains(.schemaVersion) || fields.contains(.tool)
            guard audit != entitlements else {
                throw ReportError.invalidContents("Unrecognized or ambiguous report schema. Choose an AIRS audit or an entitlement comparison report.")
            }
            if audit {
                guard try fields.decode(Int.self, forKey: .schema_version) == 1,
                      try fields.decode(String.self, forKey: .report_kind) == "airs.audit" else {
                    throw ReportError.invalidContents("Unsupported AIRS report kind or schema version. Only schema-1 audit reports can be opened here.")
                }
                kind = .audit
            } else {
                guard try fields.decode(Int.self, forKey: .schemaVersion) == 1,
                      try fields.decode(String.self, forKey: .tool) == "EntitlementDiff" else {
                    throw ReportError.invalidContents("Unsupported entitlement report tool or schema version.")
                }
                kind = .entitlements
            }
        }
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= ReportFiles.maximumBytes else { throw ReportError.tooLarge(ReportFiles.maximumBytes) }
        switch try JSONDecoder().decode(Envelope.self, from: data).kind {
        case .audit: return .audit(try AuditReport.decode(data), data)
        case .entitlements: return .entitlements(try SavedReport.parse(data))
        }
    }

    static func read(_ url: URL) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            return try parse(ReportFiles.readBounded(url))
        }.value
    }
}

/// One file-open owner for the existing AIRS window. Rejected events are not queued.
@Observable @MainActor
final class AIRSFileOpen {
    private(set) var isBusy = false
    private(set) var isPresentingPanel = false
    private(set) var isTerminating = false
    private(set) var status = ""
    var errorMessage: String?
    private var activeTask: Task<Void, Never>?
    private let read: @Sendable (URL) async throws -> AIRSOpenedReport
    private let hasModal: @MainActor () -> Bool

    init(read: @escaping @Sendable (URL) async throws -> AIRSOpenedReport = { try await AIRSOpenedReport.read($0) },
         hasModal: @escaping @MainActor () -> Bool = {
             NSApp?.modalWindow != nil || NSApp?.windows.contains(where: { $0.attachedSheet != nil }) == true
         }) {
        self.read = read; self.hasModal = hasModal
    }

    var blocksActions: Bool { isBusy || isPresentingPanel || isTerminating }

    func chooseReport(audit: AuditWorkspace, entitlements: EntitlementsWorkspace, navigation: AIRSNavigation) {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal() else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Open Report"
        panel.message = "Open an AIRS audit or entitlement comparison. The report schema selects the workspace."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { open([url], audit: audit, entitlements: entitlements, navigation: navigation) }
    }

    @discardableResult
    func open(_ urls: [URL], audit: AuditWorkspace, entitlements: EntitlementsWorkspace,
              navigation: AIRSNavigation) -> Task<Void, Never>? {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal() else {
            status = "File was not opened. Finish the current action, then open it again."
            return nil
        }
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            errorMessage = "Open exactly one local file or app at a time."
            return nil
        }
        // Preserve the existing explicit binary/app route; JSON never falls through to analysis.
        guard url.pathExtension.lowercased() == "json" else {
            status = ""
            navigation.performAudit { audit.analyze(url) }
            return nil
        }
        let auditRevision = audit.reportRevision
        let entitlementRevision = entitlements.model.reportRevision
        isBusy = true
        status = "Opening report…"
        let task = Task {
            defer { isBusy = false; activeTask = nil }
            do {
                let report = try await read(url)
                try Task.checkCancellation()
                guard !isTerminating, !audit.blocksFileOpen, !entitlements.isBusy,
                      audit.reportRevision == auditRevision,
                      entitlements.model.reportRevision == entitlementRevision else {
                    status = "Workspace changed; the report was not opened. Open it again when ready."
                    return
                }
                switch report {
                case .audit(let report, let bytes):
                    audit.openValidatedReport(report, data: bytes, from: url)
                    navigation.showsEntitlements = false
                case .entitlements(let report):
                    entitlements.reviewValidatedReport(report, from: url)
                    navigation.showsEntitlements = true
                }
                status = ""
            } catch {
                if Task.isCancelled || isTerminating || error is CancellationError {
                    status = "File opening cancelled. Existing sessions are unchanged."
                } else {
                    errorMessage = error.localizedDescription
                    status = "Report was not opened. Existing sessions are unchanged."
                }
            }
        }
        activeTask = task
        return task
    }

    func cancel() { activeTask?.cancel() }
    func finishBeforeQuit() async {
        isTerminating = true
        activeTask?.cancel()
        await activeTask?.value
    }
    func resumeAfterCancelledQuit() { isTerminating = false }
}
