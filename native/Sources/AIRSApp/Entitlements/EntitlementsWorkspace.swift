import AppKit
import Observation
import UniformTypeIdentifiers
import AIRSEntitlements
import EntitlementDiffCore
import EntitlementDiffModel
import EntitlementDiffSecurity

struct EntitlementFindSession: Identifiable {
    let id = UUID()
    let reportRevision: UUID
}

struct EntitlementBatchManifestReview: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let pairs: [EntitlementBatchPair]
    let replacedPairCount: Int
    var usesRelativePaths = false
}

/// AIRS owns panels and settlement; the donor owns typed comparisons and read generations.
@Observable
@MainActor
final class EntitlementsWorkspace {
    private(set) var inspectionContexts: [ComparisonSide: InspectionCaptureContext] = [:]
    private let inspectionLibrary: InspectionLibrary
    private let writeInspectionPreferences: @Sendable (InspectionLibraryPreferences, URL) throws -> Void
    private(set) var pinnedInspectionID: UUID?
    private var inspectionPreferencesURL: URL { inspectionLibrary.storageRoot.deletingLastPathComponent().appendingPathComponent("InspectionPreferences.json") }
    private(set) var inspectionEntries: [InspectionLibraryEntry] = []
    var inspectionReview: InspectionCaptureContext?
    private(set) var showingInspectionLibrary = false
    var captureName = ""
    var captureSide: ComparisonSide?

    let model: ComparisonModel
    private(set) var isWorking = false
    private(set) var isWriting = false
    private(set) var isPresentingPanel = false
    private(set) var isTerminating = false
    private(set) var status = "Choose one app to inspect its entitlements, or two apps to compare."
    private(set) var showingLibrary = false
    private(set) var libraryEntries: [EntitlementLibraryEntry] = []
    private(set) var libraryLoaded = false
    private let library: EntitlementReportLibrary
    private let reader: any SnapshotReading
    private let batchRunner: EntitlementBatchRunner
    private(set) var showingBatch = false
    private(set) var batchPairs: [EntitlementBatchPair] = []
    private(set) var batchResult: EntitlementBatchResult?
    private(set) var batchPrevious: URL?
    private(set) var batchCurrent: URL?
    private(set) var batchArchitecture: Architecture = .arm64
    private var batchExecutionID: UUID?
    var batchManifestReview: EntitlementBatchManifestReview?
    private var sourceBatchManifestURL: URL?
    private let readBatchManifest: @Sendable (URL) async throws -> EntitlementBatchManifest
    var canImportBatchManifest: Bool { canEditBatch }
    var canExportBatchManifest: Bool { !isBusy && !batchPairs.isEmpty }
    /// Use this workspace's actual selected history owner, never a guessed default path.
    func preparePortableBatchHistory(_ project:InspectionProject) async throws -> PortableSettledBatchEvidence {
        try await PortableSettledBatchEvidence.prepare(project:project,history:batchHistory)
    }
    private let batchHistory: EntitlementBatchHistory
    private(set) var showingBatchHistory = false
    private(set) var batchHistoryEntries: [EntitlementBatchHistoryEntry] = []
    private(set) var batchHistoryLoaded = false
    private(set) var selectedBatchHistory: EntitlementBatchRecord?
    private(set) var batchNeedsHistorySave = false
    private(set) var batchHistoryFailure: String?
    private var pendingBatchHistoryData: Data?
    private var batchFinishedAt: Date?
    private let recovery: EntitlementBatchRecovery
    private let readerContext: @Sendable () throws -> EntitlementReaderContext
    private(set) var batchCheckpoint: EntitlementBatchCheckpoint?
    private(set) var showingBatchRecovery = false
    private(set) var recoveryEntries: [EntitlementRecoveryEntry] = []
    var batchNeedsCheckpointSave: Bool { batchCheckpoint?.persistenceError != nil }
    var canResumeBatch: Bool {
        !isBusy && !batchNeedsCheckpointSave && !batchNeedsHistorySave && !hasUnretainedBatchReport &&
        batchCheckpoint?.result.settled == true && batchCheckpoint?.hasRemainingPairs == true
    }
    var canLeaveForRecovery: Bool {
        !isBusy && batchCheckpoint?.checkpointRevision != nil && !batchNeedsCheckpointSave && batchCheckpoint?.result.settled == true
    }

    nonisolated static var batchHistoryRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIRS/EntitlementBatchHistory", isDirectory: true)
    }
    var errorMessage: String?
    var focusedValue: FocusedValueSelection?
    var savedReport: SavedReport?
    var entitlementFind: EntitlementFindSession?
    private(set) var findRevealID: String?
    private(set) var findRevealRevision = UUID()
    private var pendingFindReveal: (id: String, reportRevision: UUID)?
    private var reviewURL: URL?
    private var protectedSavedReportURL: URL?
    private var activeTask: Task<Void, Never>?
    private var operationID = UUID()
    private var writeFailed = false
    private var isInspecting = false
    private let readReport: @Sendable (URL) async throws -> SavedReport
    private let writeReport: @Sendable (EntitlementDiffCore.ComparisonReport, URL, [URL]) async throws -> Void
    private let writeTextReport: (@Sendable (EntitlementDiffCore.ComparisonReport, URL, [URL]) async throws -> Void)?

    init(library: EntitlementReportLibrary = EntitlementReportLibrary(),
         batchHistory: EntitlementBatchHistory = EntitlementBatchHistory(root: EntitlementsWorkspace.batchHistoryRoot),
         recovery: EntitlementBatchRecovery? = nil,
         readerContext: @escaping @Sendable () throws -> EntitlementReaderContext = {
             guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
             return try EntitlementReaderContext.capture(executable: executable)
         },
         batchRunner: EntitlementBatchRunner = EntitlementBatchRunner(),
         reader: any SnapshotReading = SecurityEntitlementReader(),
         inspectionLibrary: InspectionLibrary = InspectionLibrary(root: URL.applicationSupportDirectory.appendingPathComponent("AIRS/InspectionLibrary")),
         writeInspectionPreferences: @escaping @Sendable (InspectionLibraryPreferences, URL) throws -> Void = { try $0.write(to: $1) },
         readBatchManifest: @escaping @Sendable (URL) async throws -> EntitlementBatchManifest = { try await EntitlementsWorkspace.readManifest($0) },
         readReport: @escaping @Sendable (URL) async throws -> SavedReport = { try await EntitlementsWorkspace.readSaved($0) },
         writeReport: @escaping @Sendable (EntitlementDiffCore.ComparisonReport, URL, [URL]) async throws -> Void = { try await EntitlementsWorkspace.writeSaved($0, $1, $2) },
         writeTextReport: (@Sendable (EntitlementDiffCore.ComparisonReport, URL, [URL]) async throws -> Void)? = nil) {
        self.inspectionLibrary = inspectionLibrary
        self.writeInspectionPreferences = writeInspectionPreferences
        self.library = library
        self.batchHistory = batchHistory
        self.recovery = recovery ?? EntitlementBatchRecovery(root: batchHistory.storageRoot.deletingLastPathComponent().appendingPathComponent("EntitlementBatchRecovery"))
        self.readerContext = readerContext
        self.reader = reader
        self.batchRunner = batchRunner
        model = ComparisonModel(reader: reader, architecture: .arm64)
        self.readBatchManifest = readBatchManifest
        self.readReport = readReport
        self.writeReport = writeReport
        self.writeTextReport = writeTextReport
    }

    /// A failed/loading/empty side is never presented as a successful empty snapshot.
    /// Two ready inputs continue through the existing comparison path.
    var standaloneInspection: StandaloneEntitlementInspection? {
        switch (model.previous.snapshot, model.current.snapshot) {
        case (.some(let snapshot), .none):
            return .init(side: .previous, snapshot: snapshot, revision: model.reportRevision)
        case (.none, .some(let snapshot)):
            return .init(side: .current, snapshot: snapshot, revision: model.reportRevision)
        default:
            return nil
        }
    }

    var isBusy: Bool { inspectionReview != nil || captureSide != nil || isWorking || isPresentingPanel || savedReport != nil || focusedValue != nil || entitlementFind != nil || batchManifestReview != nil || isTerminating }
    var canFindEntitlement: Bool { !isBusy && !showingInspectionLibrary && !showingLibrary && !showingBatch && !showingBatchHistory && !showingBatchRecovery && errorMessage == nil && model.report != nil }
    var canCancel: Bool { isWorking && !isWriting && !isTerminating }
    var requiresQuitSettlement: Bool { isWorking || isPresentingPanel || hasUnretainedBatchReport || batchNeedsHistorySave || batchNeedsCheckpointSave }
    var hasUnretainedBatchReport: Bool { batchResult?.hasUnretainedReport == true }
    var canEditBatch: Bool { !isBusy && batchResult == nil }
    var canRunBatch: Bool { canEditBatch && !batchPairs.isEmpty }
    var projectProtectedInputs:[URL]=[]
    var projectHistoryIDs:[UUID:[UUID]]=[:]
    var protectedInputs: [URL] {
        let primary = model.selectedSourceURLs + [protectedSavedReportURL, sourceBatchManifestURL].compactMap { $0 }
        let currentBatch = batchPairs.flatMap { [$0.previous, $0.current] }
            + (batchResult?.rows.compactMap(\.exportedReportURL) ?? [])
        let historical = selectedBatchHistory?.result.rows.flatMap { row in
            [row.pair.previous, row.pair.current] + [row.exportedReportURL].compactMap { $0 }
        } ?? []
        return projectProtectedInputs + primary + inspectionContexts.values.compactMap(\.sourceURL) + [inspectionLibrary.storageRoot, inspectionPreferencesURL, library.storageRoot, batchHistory.storageRoot, recovery.storageRoot] + currentBatch + historical
    }

    // Reuse the donor browser's exact lookup and visible-order navigation.
    func canMoveToChange(_ direction: ComparisonBrowser.ChangeDirection) -> Bool {
        canFindEntitlement && model.browser.changeTarget(direction) != nil
    }

    func moveToChange(_ direction: ComparisonBrowser.ChangeDirection) {
        guard canMoveToChange(direction), let id = model.browser.moveToChange(direction) else { return }
        findRevealID = id
        findRevealRevision = UUID()
        status = ""
    }

    func beginFindEntitlement() {
        guard canFindEntitlement else { return }
        entitlementFind = EntitlementFindSession(reportRevision: model.reportRevision)
    }

    func cancelFindEntitlement(sessionID: UUID) {
        guard entitlementFind?.id == sessionID else { return }
        entitlementFind = nil
    }

    func findEntitlement(_ key: String, revealHidden: Bool, sessionID: UUID) -> ComparisonBrowser.ExactFindResult {
        guard let session = entitlementFind, session.id == sessionID,
              session.reportRevision == model.reportRevision, model.report != nil,
              !isWorking, !isPresentingPanel, !isTerminating, savedReport == nil,
              focusedValue == nil, errorMessage == nil else { return .missing }
        let result = model.browser.findExactKey(key, revealHidden: revealHidden)
        if case .found(let id) = result {
            pendingFindReveal = (id, session.reportRevision)
            entitlementFind = nil
            status = "Exact entitlement selected. Reports still include the complete comparison."
        }
        return result
    }

    /// A hidden-key reveal expands the table projection. Wait for sheet dismissal
    /// so the reused table can scroll to rows that were absent during Find.
    func finishFindPresentation() {
        guard let pending = pendingFindReveal else { return }
        pendingFindReveal = nil
        guard !isBusy, pending.reportRevision == model.reportRevision,
              model.browser.selection == pending.id, model.browser.selectedRow?.id == pending.id else { return }
        findRevealID = pending.id
        findRevealRevision = UUID()
    }

    nonisolated static func readSaved(_ url: URL) async throws -> SavedReport {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try SavedReport.read(at: url)
        }.value
    }

    nonisolated static func writeSaved(_ report: EntitlementDiffCore.ComparisonReport, _ url: URL, _ inputs: [URL]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try ReportDestination.validate(url, excluding: inputs)
            let bytes = try report.jsonData()
            try ReportDestination.validate(url, excluding: inputs)
            try bytes.write(to: url, options: .atomic)
        }.value
    }

    /// Complete existing text serialization, independent of the visible filter.
    /// Text is a readable summary of all differences and unchanged-key count;
    /// it is not a schema-1 import document or a full unchanged-value snapshot.
    nonisolated static func writeTextSaved(_ report: EntitlementDiffCore.ComparisonReport, _ url: URL, _ inputs: [URL]) async throws {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try ReportDestination.validate(url, excluding: inputs)
            let bytes = Data(report.text().utf8)
            try ReportDestination.validate(url, excluding: inputs)
            try bytes.write(to: url, options: .atomic)
        }.value
    }

    /// One bounded host operation. Even cancelled native calls retain ownership until settled.
    @discardableResult
    private func begin(writing: Bool = false, inspecting: Bool = false, _ body: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        isWorking = true; isWriting = writing; isInspecting = inspecting; writeFailed = false
        let id = UUID(); operationID = id
        let task = Task {
            defer {
                if operationID == id { isWorking = false; isWriting = false; isInspecting = false; activeTask = nil }
            }
            do { try await body() }
            catch is CancellationError { status = "Operation cancelled." }
            catch {
                if !writing && Task.isCancelled { status = "Operation cancelled."; return }
                if writing { writeFailed = true }
                errorMessage = error.localizedDescription
                status = "Operation failed; no successful result was substituted."
            }
        }
        activeTask = task
        return task
    }

    /// Build a document only for this successful read revision. Metadata failure
    /// leaves the actual read visible and makes capture explicitly unavailable.
    private func prepareCapture(_ side: ComparisonSide) async {
        let state = side == .previous ? model.previous : model.current
        guard let snapshot = state.snapshot, !snapshot.isSavedBaseline, model.selectedSourceURL(for: side) != nil else { return }
        let revision = model.reportRevision
        let completedAt = Date()
        do {
            let context = try await Task.detached(priority: .userInitiated) {
                let document = try InspectionDocument(snapshot: snapshot, capturedAt: completedAt,
                    producerVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1-development")
                return InspectionCaptureContext(document: document, data: try InspectionDocumentCodec.encode(document))
            }.value
            try Task.checkCancellation()
            guard model.reportRevision == revision else { return }
            inspectionContexts[side] = context
        } catch {
            if !Task.isCancelled { status = "Inspection succeeded, but baseline capture is unavailable: " + error.localizedDescription }
        }
    }

    func requestCapture(_ side: ComparisonSide) {
        guard !isBusy, inspectionContexts[side] != nil else { return }
        captureName = inspectionContexts[side]?.document.snapshot.sourceName ?? ""
        captureSide = side
    }

    @discardableResult
    func captureBaseline(_ side: ComparisonSide, label: String) -> Task<Void, Never>? {
        guard !isBusy, let context = inspectionContexts[side] else { return nil }
        return begin(writing: true) {
            _ = try await self.inspectionLibrary.keep(context.data, label: label)
            self.inspectionEntries = try await self.inspectionLibrary.entries()
            self.status = "Baseline retained. Original application binaries are not stored."
        }
    }

    @discardableResult
    func openInspectionLibrary() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        showingInspectionLibrary = true
        return begin {
            self.inspectionEntries = try await self.inspectionLibrary.entries()
            var preferences = try InspectionLibraryPreferences.read(at: self.inspectionPreferencesURL)
            if let id = preferences.pinnedBaselineID, !self.inspectionEntries.contains(where: { $0.id == id && $0.issue == nil }) {
                preferences.pinnedBaselineID = nil
                try self.writeInspectionPreferences(preferences, self.inspectionPreferencesURL)
                self.status = "Default baseline is unavailable; the default was cleared."
            }
            self.pinnedInspectionID = preferences.pinnedBaselineID
        }
    }
    @discardableResult
    func pinInspection(_ id: UUID?) -> Task<Void, Never>? {
        guard !isBusy, id == nil || inspectionEntries.contains(where: { $0.id == id && $0.issue == nil }) else { return nil }
        return begin(writing: true) {
            let preferences = InspectionLibraryPreferences(pinnedBaselineID: id)
            try self.writeInspectionPreferences(preferences, self.inspectionPreferencesURL)
            self.pinnedInspectionID = id
            self.status = id == nil ? "Default baseline cleared." : "Default baseline saved. Review it before adoption."
        }
    }

    @discardableResult
    func removeInspection(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return begin(writing: true) {
            if self.pinnedInspectionID == id {
                try self.writeInspectionPreferences(.init(), self.inspectionPreferencesURL)
                self.pinnedInspectionID = nil
            }
            try await self.inspectionLibrary.remove(id)
            self.inspectionEntries = try await self.inspectionLibrary.entries()
            self.status = "Retained baseline removed. Active snapshots and original apps are unchanged."
        }
    }

    func closeInspectionLibrary() { guard !isBusy else { return }; showingInspectionLibrary = false }

    @discardableResult
    func reviewInspection(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return begin {
            let retained = try await self.inspectionLibrary.load(id)
            try Task.checkCancellation()
            self.inspectionReview = InspectionCaptureContext(document: retained.report,
                data: retained.data, sourceURL: retained.reportURL, label: retained.provenance.sourceLabel)
        }
    }

    func reviewValidatedInspection(_ document: InspectionDocument, data: Data, from url: URL) {
        guard !isBusy else { return }
        inspectionReview = InspectionCaptureContext(document: document, data: data, sourceURL: url)
    }

    func adoptInspection(_ action: InspectionReviewAction) {
        guard !isWorking, !isTerminating, let context = inspectionReview else { return }
        model.useSavedBaseline(context.document.snapshot)
        inspectionContexts = [.previous: context]
        protectedSavedReportURL = context.sourceURL
        inspectionReview = nil
        showingInspectionLibrary = false
        showingLibrary = false; showingBatch = false; showingBatchHistory = false; showingBatchRecovery = false
        status = action == .inspect ? "Browsing saved inspection; no app was read." : "Saved Previous baseline ready. Choose a Current app."
    }

    @discardableResult
    func exportInspection(_ side: ComparisonSide, to url: URL) -> Task<Void, Never>? {
        guard !isBusy, let context = inspectionContexts[side] else { return nil }
        let inputs = protectedInputs
        return begin(writing: true) {
            try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try ReportDestination.validate(url, excluding: inputs)
                try context.data.write(to: url, options: .atomic)
            }.value
            self.status = "Complete inspection exported."
        }
    }

    func chooseInspectionExport(_ side: ComparisonSide) {
        guard !isBusy, inspectionContexts[side] != nil else { return }
        isPresentingPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Inspection"
        panel.allowedContentTypes = [UTType(filenameExtension: "airsinspect") ?? .json]
        panel.nameFieldStringValue = "Inspection.airsinspect"
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { exportInspection(side, to: url) }
    }

    @discardableResult
    func inspect(_ url: URL, side: ComparisonSide) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        status = "Reading \(side.label.lowercased()) app metadata…"
        inspectionContexts[side] = nil
        let read = model.load(url, side: side)
        return begin(inspecting: true) {
            await read.value
            try Task.checkCancellation()
            await self.prepareCapture(side)
            if self.inspectionContexts[side] != nil {
                self.status = "Inspection settled. Metadata extraction does not validate a signature."
            }
        }
    }

    @discardableResult
    func inspectSingle(_ url: URL) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        inspectionContexts.removeAll(); protectedSavedReportURL = nil
        model.clear()
        showComparison()
        return inspect(url, side: .previous)
    }

    @discardableResult
    func inspectPair(previous: URL, current: URL) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        inspectionContexts.removeAll()
        protectedSavedReportURL = nil
        showComparison()
        let reads = [(ComparisonSide.previous, model.load(previous, side: .previous)),
                     (ComparisonSide.current, model.load(current, side: .current))]
        return begin(inspecting: true) {
            for (_, task) in reads { await task.value }
            try Task.checkCancellation()
            for (side, _) in reads { await self.prepareCapture(side) }
            self.status = "Requested pair settled. Missing slices and failed reads remain explicit."
        }
    }

    func choose(_ side: ComparisonSide) {
        guard !isBusy else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Choose \(side.label) Application"
        panel.message = "Inspect the main executable's \(model.architecture.rawValue) declarations without launching the app."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Inspect"
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { inspect(url, side: side) }
    }

    func drop(_ urls: [URL], side: ComparisonSide) -> Bool {
        guard !isBusy else { return false }
        do { inspect(try ApplicationDrop.applicationURL(from: urls), side: side); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func reload(_ side: ComparisonSide) {
        guard let url = model.selectedSourceURL(for: side) else { return }
        inspect(url, side: side)
    }

    func reveal(_ side: ComparisonSide) {
        guard !isBusy, let url = model.selectedSourceURL(for: side) else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clear(_ side: ComparisonSide? = nil) {
        guard !isBusy else { return }
        if let side { inspectionContexts[side] = nil; model.clear(side) } else {
            inspectionContexts.removeAll()
            model.clear(); protectedSavedReportURL = nil
        }
        status = "Selection cleared."
    }

    var canChangeArchitecture: Bool {
        !isBusy && ![model.previous.snapshot, model.current.snapshot].compactMap({ $0 }).contains(where: \.isSavedBaseline)
    }
    var architectureChangeReason: String {
        canChangeArchitecture ? "Live selections are re-read for the requested architecture; no fallback." : "Clear saved baselines before changing architecture."
    }
    func waitForSettlement() async { await activeTask?.value }

    func setArchitecture(_ architecture: Architecture) {
        guard !isBusy, architecture != model.architecture else { return }
        guard canChangeArchitecture else { status = architectureChangeReason; return }
        let selections = ComparisonSide.allCases.compactMap { side in
            model.selectedSourceURL(for: side).map { (side, $0) }
        }
        inspectionContexts.removeAll()
        model.setArchitecture(architecture); protectedSavedReportURL = nil
        let reads = selections.map { ($0.0, model.load($0.1, side: $0.0)) }
        guard !reads.isEmpty else {
            status = "Architecture changed. Synthetic example cleared; no app was re-read."
            return
        }
        begin(inspecting: true) {
            for (_, task) in reads { await task.value }
            try Task.checkCancellation()
            for (side, _) in reads { await self.prepareCapture(side) }
            self.status = "Selected apps re-read for the requested architecture. No fallback slice is used."
        }
    }

    func swap() {
        guard !isBusy, model.swap() else { return }
        let previous = inspectionContexts[.previous]
        inspectionContexts[.previous] = inspectionContexts[.current]
        inspectionContexts[.current] = previous
    }
    func loadExample() {
        guard !isBusy else { return }
        protectedSavedReportURL = nil
        inspectionContexts.removeAll()
        model.loadExample(structured: true)
        status = "Synthetic values; no app was inspected."
    }

    func chooseSavedReport() {
        guard !isBusy else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Open Entitlement Report"
        panel.message = "Choose a schema-1 entitlement comparison. Saved metadata is unverified."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { openSavedReport(url) }
    }

    @discardableResult
    func openSavedReport(_ url: URL) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let revision = model.reportRevision
        status = "Reading saved entitlement report…"
        return begin {
            let saved = try await self.readReport(url)
            try Task.checkCancellation()
            guard self.model.reportRevision == revision else { return }
            self.reviewURL = url; self.savedReport = saved
            self.status = "Review saved snapshots before replacing the comparison."
        }
    }

    func adoptSavedBaseline(_ snapshot: EntitlementSnapshot) {
        guard !isWorking, !isTerminating, savedReport != nil else { return }
        inspectionContexts.removeAll()
        model.useSavedBaseline(snapshot)
        finishReview()
    }

    /// Shared file routing stages the existing review; adoption remains explicit.
    func reviewValidatedReport(_ report: SavedReport, from url: URL) {
        guard !isBusy else { return }
        reviewURL = url; savedReport = report
        status = "Review saved snapshots before replacing the comparison."
    }
    func openSavedComparison() {
        guard !isWorking, !isTerminating, let savedReport else { return }
        inspectionContexts.removeAll()
        model.openSavedComparison(savedReport)
        finishReview()
    }
    private func finishReview() {
        showingLibrary = false; showingBatch = false; showingBatchHistory = false; showingBatchRecovery = false
        protectedSavedReportURL = reviewURL
        savedReport = nil; reviewURL = nil
        status = "Saved metadata opened; comparisons recomputed. No source app was read."
    }
    func cancelReview() { savedReport = nil; reviewURL = nil }

    @discardableResult
    func openLibrary() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        showingInspectionLibrary = false
        showingLibrary = true; showingBatch = false; showingBatchHistory = false; showingBatchRecovery = false
        return refreshLibrary()
    }

    func closeLibrary() { guard !isBusy else { return }; showingLibrary = false }

    /// Return to the primary comparison without clearing inputs, queue or recovery state.
    func showComparison() {
        guard !isBusy else { return }
        showingInspectionLibrary = false
        showingLibrary = false; showingBatch = false
        showingBatchHistory = false; showingBatchRecovery = false
    }

    @discardableResult
    func refreshLibrary() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        status = "Reading retained entitlement reports…"
        return begin {
            let entries = try await self.library.entries()
            try Task.checkCancellation()
            self.libraryEntries = entries; self.libraryLoaded = true
            self.status = "Entitlement library refreshed. Saved metadata remains unverified."
        }
    }

    @discardableResult
    func keepCurrentReport() -> Task<Void, Never>? {
        guard !isBusy, let report = model.report else { return nil }
        status = "Keeping complete entitlement comparison…"
        return begin(writing: true) {
            _ = try await self.library.keep(report)
            self.status = "Complete entitlement comparison kept."
            // A refresh failure must not misreport the already-completed write.
            do {
                self.libraryEntries = try await self.library.entries(); self.libraryLoaded = true
            } catch { self.errorMessage = "Report kept, but the library could not refresh: \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func reviewRetainedReport(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let revision = model.reportRevision
        status = "Reading retained entitlement report…"
        return begin {
            let retained = try await self.library.load(id)
            try Task.checkCancellation()
            guard self.model.reportRevision == revision else { return }
            self.reviewURL = retained.reportURL; self.savedReport = retained.report
            self.status = "Review retained snapshots before replacing the comparison."
        }
    }

    @discardableResult
    func removeRetainedReport(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        status = "Moving retained entitlement report to Trash…"
        return begin(writing: true) {
            try await self.library.remove(id)
            self.libraryEntries.removeAll { $0.id == id }
            self.status = "Retained copy moved to Trash."
        }
    }

    nonisolated static func readManifest(_ url: URL) async throws -> EntitlementBatchManifest {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try EntitlementBatchManifest.read(url)
        }.value
    }

    func chooseBatchManifest() {
        guard canImportBatchManifest else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Import Entitlement Batch Manifest"
        panel.message = "Review an ordered selection plan before replacing the queue. Import does not inspect apps."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let result = panel.runModal(); isPresentingPanel = false
        if result == .OK, let url = panel.url { openBatchManifest(url) }
    }

    @discardableResult
    func openBatchManifest(_ url: URL) -> Task<Void, Never>? {
        guard canImportBatchManifest else { return nil }
        return begin {
            let manifest = try await self.readBatchManifest(url)
            try Task.checkCancellation()
            self.batchManifestReview = .init(sourceURL: url, pairs: manifest.makePairs(), replacedPairCount: self.batchPairs.count, usesRelativePaths: manifest.version == 2)
            self.showingBatch = true; self.showingBatchHistory = false; self.showingBatchRecovery = false; self.showingLibrary = false
            self.status = "Review the imported selection plan. No app was read and the current queue is unchanged."
        }
    }

    func adoptBatchManifest(_ reviewID: UUID) {
        guard !isWorking, !isTerminating, !isPresentingPanel, batchResult == nil,
              let review = batchManifestReview, review.id == reviewID else { return }
        batchPairs = review.pairs
        sourceBatchManifestURL = review.sourceURL
        batchPrevious = nil; batchCurrent = nil; batchExecutionID = nil
        batchManifestReview = nil
        status = "Manifest selections adopted. Review the queue, then explicitly Run and Keep Comparisons. Apps will be checked at run admission."
    }

    func cancelBatchManifest(_ reviewID: UUID) {
        guard batchManifestReview?.id == reviewID else { return }
        batchManifestReview = nil
        status = "Manifest import cancelled. The current queue is unchanged."
    }

    func chooseBatchManifestExport(relativePaths: Bool = false) {
        guard canExportBatchManifest else { return }
        isPresentingPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Entitlement Batch Manifest"
        panel.message = relativePaths
            ? "Save beside or above every selected app folder. Paths will be relative to this manifest, so the plan can move with those folders. Apps and results are not copied."
            : "Save ordered app selections and architecture. This plan includes full local paths; it contains no results or resume state."
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "AIRS-entitlement-batch.json"
        let result = panel.runModal(); isPresentingPanel = false
        if result == .OK, let url = panel.url { exportBatchManifest(to: url, relativePaths: relativePaths) }
    }

    @discardableResult
    func exportBatchManifest(to url: URL, relativePaths: Bool = false) -> Task<Void, Never>? {
        guard canExportBatchManifest else { return nil }
        let pairs = batchPairs, inputs = protectedInputs
        return begin(writing: true) {
            try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try EntitlementBatchManifest(pairs: pairs, relativeTo: relativePaths ? url.deletingLastPathComponent() : nil).write(to: url, excluding: inputs)
            }.value
            self.status = relativePaths
                ? "Batch manifest exported with paths relative to its folder. Move it with the selected app folders; no apps, results or recovery state were copied."
                : "Batch manifest exported with full local paths. No apps were read; results and recovery state were not exported."
        }
    }

    func openBatch() {
        guard !isBusy else { return }
        showingInspectionLibrary = false
        showingBatch = true; showingLibrary = false; showingBatchHistory = false; showingBatchRecovery = false
    }
    func closeBatch() { guard !isBusy else { return }; showingBatch = false }

    func setBatchArchitecture(_ architecture: Architecture) {
        guard canEditBatch else { return }; batchArchitecture = architecture
    }

    func chooseBatchInput(_ side: ComparisonSide) {
        guard canEditBatch else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Batch: Choose \(side.label) Application"
        panel.message = "Add an explicit pair. Apps are read only when Run and Keep Comparisons starts."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        let result = panel.runModal()
        isPresentingPanel = false
        guard result == .OK, let url = panel.url else { return }
        if side == .previous { batchPrevious = url } else { batchCurrent = url }
    }

    func addSelectedBatchPair() {
        guard let previous = batchPrevious, let current = batchCurrent else { return }
        addBatchPair(previous: previous, current: current, architecture: batchArchitecture)
    }
    func addBatchPair(previous: URL, current: URL, architecture: Architecture) {
        guard canEditBatch, batchPairs.count < EntitlementBatchRunner.maximumPairs else { return }
        batchPairs.append(.init(previous: previous, current: current, architecture: architecture))
    }
    func removeBatchPair(_ id: UUID) {
        guard canEditBatch else { return }; batchPairs.removeAll { $0.id == id }
    }
    func clearBatch() {
        guard !isBusy, !hasUnretainedBatchReport, !batchNeedsHistorySave, !batchNeedsCheckpointSave else { return }
        batchExecutionID = nil; batchResult = nil; batchCheckpoint = nil; batchPairs = []; sourceBatchManifestURL = nil
        batchPrevious = nil; batchCurrent = nil
        pendingBatchHistoryData = nil; batchFinishedAt = nil; batchHistoryFailure = nil
        status = "Batch queue cleared. Retained reports remain in the entitlement library."
    }

    @discardableResult
    func runBatch() -> Task<Void, Never>? {
        guard canRunBatch else { return nil }
        return executeBatch(resuming: nil)
    }

    @discardableResult
    func resumeBatch() -> Task<Void, Never>? {
        guard canResumeBatch, let checkpoint = batchCheckpoint else { return nil }
        return executeBatch(resuming: checkpoint)
    }

    private func executeBatch(resuming previous: EntitlementBatchCheckpoint?) -> Task<Void, Never> {
        let pairs = batchPairs
        let execution = UUID(); batchExecutionID = execution
        let batchID = previous?.id ?? execution
        status = "Running bounded entitlement comparisons…"
        return begin { [batchRunner, reader, library, recovery, readerContext] in
            try await recovery.acquire(batchID, expecting: previous.map { [$0.executionID] }, revision: previous?.checkpointRevision)
            do {
                let context = try readerContext()
                let current: EntitlementBatchCheckpoint?
                if let previous { current = try await recovery.load(previous.id) } else { current = nil }
                let checkpoint = try await batchRunner.runRecoverable(pairs: pairs, id: execution, reader: reader,
                    context: context, resuming: current,
                    retain: { try await library.keep($0) }, checkpoint: { try await recovery.save($0) },
                    progress: { [weak self] in await self?.receiveCheckpoint($0, execution: execution) })
                self.receiveCheckpoint(checkpoint, execution: execution)
                self.batchFinishedAt = checkpoint.finishedAt
                self.batchNeedsHistorySave = true; self.pendingBatchHistoryData = nil
                self.status = checkpoint.persistenceError ?? (checkpoint.needsReportRecovery ? "A complete report needs saving." : "Batch settled. Completed reports are available for review.")
                if checkpoint.persistenceError == nil { await self.persistSettledBatchHistory() }
                await recovery.release(batchID)
            } catch { await recovery.release(batchID); throw error }
        }
    }

    private func receiveCheckpoint(_ checkpoint: EntitlementBatchCheckpoint, execution: UUID) {
        guard batchExecutionID == execution, checkpoint.executionID == execution else { return }
        batchCheckpoint = checkpoint; batchResult = checkpoint.result
    }

    /// All changes following a run use the same revision-bound ownership boundary.
    private func withRecoveryLease(_ body: @MainActor () async throws -> Void) async throws {
        guard let checkpoint = batchCheckpoint else { try await body(); return }
        try await recovery.acquire(checkpoint.id, expecting: [checkpoint.executionID], revision: checkpoint.checkpointRevision)
        do { try await body(); await recovery.release(checkpoint.id) }
        catch { await recovery.release(checkpoint.id); throw error }
    }

    private func saveCurrentCheckpoint() async throws {
        guard var checkpoint = batchCheckpoint, let result = batchResult else { return }
        checkpoint.result = result; checkpoint.persistenceError = nil
        do {
            checkpoint.checkpointRevision = try await recovery.save(checkpoint)
            batchCheckpoint = checkpoint
        } catch {
            checkpoint.persistenceError = error.localizedDescription; batchCheckpoint = checkpoint
            throw error
        }
    }

    @discardableResult
    func retryCheckpointSave() -> Task<Void, Never>? {
        guard !isBusy, batchNeedsCheckpointSave else { return nil }
        return begin(writing: true) {
            try await self.withRecoveryLease {
                try await self.saveCurrentCheckpoint()
                await self.persistSettledBatchHistory()
            }
        }
    }

    func leaveForRecovery() {
        guard canLeaveForRecovery else { return }
        batchCheckpoint = nil; batchResult = nil; batchPairs = []; batchExecutionID = nil; sourceBatchManifestURL = nil
        batchNeedsHistorySave = false; pendingBatchHistoryData = nil; batchHistoryFailure = nil; batchFinishedAt = nil
        status = "Batch left in Recovery. Open it explicitly to save reports or resume remaining pairs."
    }

    @discardableResult
    func openBatchRecovery() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        showingInspectionLibrary = false
        showingBatchRecovery = true; showingBatch = false; showingLibrary = false; showingBatchHistory = false
        return begin { self.recoveryEntries = try await self.recovery.entries() }
    }

    @discardableResult
    func recoverBatch(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy, batchResult == nil, batchPairs.isEmpty else { return nil }
        return begin(writing: true) {
            let expected = try await self.recovery.load(id)
            let checkpoint = try await self.recovery.recover(expected)
            self.batchCheckpoint = checkpoint; self.batchResult = checkpoint.result; self.sourceBatchManifestURL = nil
            self.batchPairs = checkpoint.result.rows.map(\.pair); self.batchExecutionID = checkpoint.executionID
            self.batchFinishedAt = checkpoint.finishedAt; self.batchNeedsHistorySave = checkpoint.historyRecordID == nil
            self.pendingBatchHistoryData = nil; self.batchHistoryFailure = nil
            self.showingBatchRecovery = false; self.showingBatch = true
            self.status = "Recovery opened. Completed reports can be saved without rereading apps; resume is explicit."
        }
    }

    @discardableResult
    func removeBatchRecovery(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy, batchCheckpoint?.id != id else { return nil }
        return begin(writing: true) {
            try await self.recovery.remove(id)
            self.recoveryEntries.removeAll { $0.id == id }
            self.status = "Recovery checkpoint moved to Trash. Retained reports and settled history remain unchanged."
        }
    }

    @discardableResult
    func reviewBatchReport(_ rowID: UUID) -> Task<Void, Never>? {
        guard !isBusy, let row = batchResult?.rows.first(where: { $0.id == rowID }) else { return nil }
        if let id = row.retainedReportID { return reviewRetainedReport(id) }
        if row.exportedReportURL != nil { return reviewBatchExport(row) }
        guard let data = row.unretainedData else { return nil }
        let revision = model.reportRevision
        return begin {
            let saved = try await Task.detached { try SavedReport.parse(data) }.value
            try Task.checkCancellation()
            guard self.model.reportRevision == revision else { return }
            self.reviewURL = nil; self.savedReport = saved
            self.status = "Review the completed session report; the batch still needs saving."
        }
    }

    @discardableResult
    func retryBatchRetention(_ rowID: UUID) -> Task<Void, Never>? {
        guard !isBusy, let result = batchResult,
              let row = result.rows.first(where: { $0.id == rowID }), let data = row.unretainedData else { return nil }
        return begin(writing: true) {
            try await self.withRecoveryLease {
                let retainedID = try await self.library.keep(data)
                guard self.batchResult?.id == result.id,
                      let index = self.batchResult?.rows.firstIndex(where: { $0.id == rowID }) else { return }
                self.batchResult?.rows[index].retainedReportID = retainedID
                self.batchResult?.rows[index].unretainedData = nil
                self.batchResult?.rows[index].message = "Complete comparison retained in the entitlement library."
                self.status = "Completed report saved; no app was reread."
                try await self.saveCurrentCheckpoint()
                await self.persistSettledBatchHistory()
            }
        }
    }

    func chooseBatchRecoveryExport(_ rowID: UUID) {
        guard !isBusy, batchResult?.rows.contains(where: { $0.id == rowID && $0.unretainedData != nil }) == true else { return }
        isPresentingPanel = true
        let panel = NSSavePanel()
        panel.title = "Save Completed Batch Comparison"
        panel.message = "Save the complete report before replacing this batch or quitting. No app is reread."
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "AIRS-entitlements.json"
        let result = panel.runModal(); isPresentingPanel = false
        if result == .OK, let url = panel.url { exportBatchRecovery(rowID, to: url) }
    }

    @discardableResult
    func exportBatchRecovery(_ rowID: UUID, to url: URL) -> Task<Void, Never>? {
        guard !isBusy, let result = batchResult,
              let row = result.rows.first(where: { $0.id == rowID }), let data = row.unretainedData else { return nil }
        let inputs = protectedInputs + result.rows.flatMap { [$0.pair.previous, $0.pair.current] }
        return begin(writing: true) {
            try await self.withRecoveryLease {
                let digest = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try ReportDestination.validate(url, excluding: inputs)
                    try data.write(to: url, options: .atomic)
                    return EntitlementBatchHistory.reportDigest(data)
                }.value
                guard self.batchResult?.id == result.id,
                      let index = self.batchResult?.rows.firstIndex(where: { $0.id == rowID }) else { return }
                self.batchResult?.rows[index].exportedReportURL = url
                self.batchResult?.rows[index].exportedReportSHA256 = digest
                self.batchResult?.rows[index].unretainedData = nil
                self.batchResult?.rows[index].message = "Complete report exported. This copy is outside the library."
                self.status = "Completed report exported; no app was reread."
                try await self.saveCurrentCheckpoint()
                await self.persistSettledBatchHistory()
            }
        }
    }

    /// Persistence belongs to settlement, even when the read task was cancelled.
    private func persistSettledBatchHistory() async {
        guard batchNeedsHistorySave, let result = batchResult, result.settled, !result.hasUnretainedReport else { return }
        isWriting = true
        do {
            if pendingBatchHistoryData == nil {
                let finishedAt = batchFinishedAt ?? Date()
                pendingBatchHistoryData = try await Task.detached {
                    try EntitlementBatchRecord(result: result, finishedAt: finishedAt).data()
                }.value
            }
            guard let data = pendingBatchHistoryData else { return }
            let historyID = try await batchHistory.keep(data)
            batchCheckpoint?.historyRecordID = historyID
            try await saveCurrentCheckpoint()
            batchNeedsHistorySave = false; batchHistoryFailure = nil; pendingBatchHistoryData = nil
            status = "Settled batch history saved. Completed reports remain available for review."
        } catch {
            batchHistoryFailure = error.localizedDescription
            status = "Batch history was not saved. Retry saving or explicitly discard its history before replacing the queue or quitting."
        }
    }

    @discardableResult
    func retryBatchHistorySave() -> Task<Void, Never>? {
        guard !isBusy, batchNeedsHistorySave, !hasUnretainedBatchReport else { return nil }
        return begin(writing: true) { try await self.withRecoveryLease { await self.persistSettledBatchHistory() } }
    }

    /// Called only after the UI's explicit discard-history confirmation.
    func discardUnsavedBatchHistory() {
        guard !isBusy, batchNeedsHistorySave, !hasUnretainedBatchReport else { return }
        batchNeedsHistorySave = false; pendingBatchHistoryData = nil; batchHistoryFailure = nil
        status = "Unsaved batch history discarded by request. Completed reports were not removed."
    }

    @discardableResult
    func openBatchHistory() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        showingInspectionLibrary = false
        showingBatchHistory = true; showingBatchRecovery = false; showingBatch = false; showingLibrary = false
        selectedBatchHistory = nil
        return refreshBatchHistory()
    }
    func closeBatchHistory() { guard !isBusy else { return }; showingBatchHistory = false; showingBatchRecovery = false }
    func backToBatchHistory() { guard !isBusy else { return }; selectedBatchHistory = nil }

    @discardableResult
    func refreshBatchHistory() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return begin {
            let entries = try await self.batchHistory.entries()
            try Task.checkCancellation()
            self.batchHistoryEntries = entries; self.batchHistoryLoaded = true
            self.status = "Entitlement batch history refreshed. Opening an outcome record never runs a comparison."
        }
    }
    @discardableResult
    func loadBatchHistory(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return begin {
            let record = try await self.batchHistory.load(id)
            try Task.checkCancellation()
            self.selectedBatchHistory = record
            self.status = "Historical outcomes opened. Current queue and comparison remain unchanged."
        }
    }
    @discardableResult
    func removeBatchHistory(_ id: UUID) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        return begin(writing: true) {
            try await self.batchHistory.remove(id)
            self.batchHistoryEntries.removeAll { $0.id == id }
            self.status = "Batch history moved to Trash. Completed reports and source apps remain unchanged."
        }
    }
    @discardableResult
    func reviewHistoryReport(_ rowID: UUID) -> Task<Void, Never>? {
        guard !isBusy, let row = selectedBatchHistory?.result.rows.first(where: { $0.id == rowID }),
              row.status == .completed else { return nil }
        if let id = row.retainedReportID { return reviewRetainedReport(id) }
        return reviewBatchExport(row)
    }

    private func reviewBatchExport(_ row: EntitlementBatchRow) -> Task<Void, Never>? {
        guard let url = row.exportedReportURL, let digest = row.exportedReportSHA256 else { return nil }
        let revision = model.reportRevision
        return begin {
            let report = try await Task.detached { try EntitlementBatchHistory.readExport(url, expectedDigest: digest) }.value
            try Task.checkCancellation()
            guard self.model.reportRevision == revision else { return }
            self.reviewURL = url; self.savedReport = report
            self.status = "Review saved snapshots from the completed comparison; no app was read."
        }
    }

    func chooseExport() {
        guard !isBusy, model.report != nil else { return }
        isPresentingPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Complete Entitlement Comparison"
        panel.message = "Both complete snapshots and all differences are exported, independently of display limits."
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AIRS-entitlements.json"
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { export(to: url) }
    }

    func chooseTextExport() {
        guard !isBusy, model.report != nil else { return }
        isPresentingPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Entitlement Text Summary"
        panel.message = "Includes every difference, unchanged-key count and scope notices. The active filter does not limit this summary. Use JSON to retain both complete snapshots."
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "AIRS-entitlements.txt"
        let result = panel.runModal()
        isPresentingPanel = false
        if result == .OK, let url = panel.url { exportText(to: url) }
    }

    @discardableResult
    func export(to url: URL) -> Task<Void, Never>? {
        guard !isBusy, let report = model.report else { return nil }
        let inputs = protectedInputs
        status = "Writing complete entitlement report…"
        return begin(writing: true) {
            try await self.writeReport(report, url, inputs)
            self.status = "Complete schema-1 entitlement report exported."
        }
    }

    @discardableResult
    func exportText(to url: URL) -> Task<Void, Never>? {
        guard !isBusy, let report = model.report else { return nil }
        let inputs = protectedInputs
        status = "Writing complete entitlement text summary…"
        return begin(writing: true) {
            if let writer = self.writeTextReport { try await writer(report, url, inputs) }
            else {
                let contexts = self.inspectionContexts
                try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = Data(InspectionSummary.text(report: report, contexts: contexts).utf8)
                    try ReportDestination.validate(url, excluding: inputs)
                    try bytes.write(to: url, options: .atomic)
                }.value
            }
            self.status = "Text summary exported with every difference and scope notice."
        }
    }

    /// A copy belongs to the selected row and report revision, never to an obsolete view.
    @discardableResult
    func copySelected(to clipboard: NSPasteboard = .general) -> Task<Void, Never>? {
        guard !isBusy, let row = model.browser.selectedRow else { return nil }
        let revision = model.reportRevision
        return begin {
            let data = try await Task.detached(priority: .userInitiated) { try row.selectedJSON() }.value
            try Task.checkCancellation()
            guard self.model.reportRevision == revision, self.model.browser.selectedRow?.id == row.id else {
                self.status = "Selection changed; nothing copied."; return
            }
            clipboard.clearContents()
            guard clipboard.setData(data, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            self.status = "Complete selected typed JSON copied, independently of the preview."
        }
    }

    func cancel() {
        guard canCancel else { return }
        activeTask?.cancel()
        if isInspecting { inspectionContexts.removeAll(); model.clear() }
        status = "Cancelling; waiting for the owned read to settle…"
    }

    func finishBeforeQuit() async -> Bool {
        isTerminating = true
        let task = activeTask
        if !isWriting { task?.cancel(); if isInspecting { inspectionContexts.removeAll(); model.clear() } }
        await task?.value
        if batchNeedsCheckpointSave {
            showingInspectionLibrary = false
            isTerminating = false; showingBatch = true; showingLibrary = false; showingBatchHistory = false; showingBatchRecovery = false
            errorMessage = "The latest recovery checkpoint has not been saved. Retry saving it before quitting."
            return false
        }
        if hasUnretainedBatchReport {
            showingInspectionLibrary = false
            isTerminating = false; showingBatch = true; showingLibrary = false; showingBatchHistory = false; showingBatchRecovery = false
            errorMessage = "A completed batch comparison has not been saved. Retry saving or export its complete report before quitting."
            return false
        }
        if batchNeedsHistorySave {
            showingInspectionLibrary = false
            isTerminating = false; showingBatch = true; showingLibrary = false; showingBatchHistory = false; showingBatchRecovery = false
            errorMessage = "Settled batch history has not been saved. Retry saving or explicitly discard its history before quitting. Completed reports remain saved."
            return false
        }
        if writeFailed { writeFailed = false; isTerminating = false; return false }
        return true
    }
    func resumeAfterCancelledQuit() { isTerminating = false }

    func copyExactKey(to clipboard: NSPasteboard = .general) {
        guard !isBusy, let key = model.browser.selectedRow?.key else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(key.utf8), forType: .string) {
            status = "Complete exact key copied as raw UTF-8 text."
        } else { errorMessage = "The system clipboard did not accept the entitlement key." }
    }

    func inspectValue(_ change: EntitlementChange, row: InspectorRow, comparisonRevision: UUID) {
        guard !isBusy, row.hasLeafValue, comparisonRevision == model.reportRevision,
              change.id == model.browser.selectedRow?.id else { return }
        focusedValue = .init(entitlementKey: change.key, pathPreview: row.displayPath,
                             previous: row.previous, current: row.current)
    }

    /// Donor serializers behind AIRS task settlement and current-selection guards.
    @discardableResult
    func copyLeaf(_ side: ComparisonSide, to clipboard: NSPasteboard = .general) -> Task<Void, Never>? {
        guard !isWorking, !isPresentingPanel, !isTerminating,
              let selection = focusedValue, let leaf = InspectorLeaf(selection.value(for: side)) else { return nil }
        let revision = model.reportRevision
        return begin {
            let data = try await Task.detached(priority: .userInitiated) { try leaf.jsonData() }.value
            try Task.checkCancellation()
            guard self.focusedValue?.id == selection.id, self.model.reportRevision == revision else {
                self.status = "Selection changed; nothing copied."; return
            }
            clipboard.clearContents()
            guard clipboard.setData(data, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            self.status = "Complete \(side.label.lowercased()) leaf JSON copied, including its type."
        }
    }

    @discardableResult
    func copyBranch(_ side: ComparisonSide, row: InspectorRow, entitlementID: String,
                    comparisonRevision: UUID, to clipboard: NSPasteboard = .general) -> Task<Void, Never>? {
        guard !isBusy, comparisonRevision == model.reportRevision,
              model.browser.selectedRow?.id == entitlementID,
              let branch = BranchJSONValue(side == .previous ? row.previous : row.current) else { return nil }
        return begin {
            let data = try await Task.detached(priority: .userInitiated) { try branch.jsonData() }.value
            try Task.checkCancellation()
            guard self.model.reportRevision == comparisonRevision,
                  self.model.browser.selectedRow?.id == entitlementID else {
                self.status = "Selection changed; nothing copied."; return
            }
            clipboard.clearContents()
            guard clipboard.setData(data, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
            self.status = "Complete \(side.label.lowercased()) branch JSON copied, including all children and their types."
        }
    }


    func copyScalarDetails(_ navigation: StringScalarNavigation, side: ComparisonSide,
                           selectionID: UUID, to clipboard: NSPasteboard = .general) {
        guard focusedValue?.id == selectionID, !isWorking && !isTerminating,
              let text = navigation.copyText(side: side), text.utf8.count <= StringScalarNavigation.copyByteLimit else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(text.utf8), forType: .string) {
            status = "\(side.label) viewed scalar details copied. Includes original Unicode and UTF-8 values."
        } else {
            errorMessage = "The system clipboard did not accept the scalar details."
        }
    }

    func copyByteContext(_ navigation: DataByteNavigation, side: ComparisonSide,
                         selectionID: UUID, to clipboard: NSPasteboard = .general) {
        guard focusedValue?.id == selectionID, !isWorking && !isTerminating,
              let text = navigation.copyText(side: side), text.utf8.count <= DataByteNavigation.copyByteLimit else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(text.utf8), forType: .string) {
            status = "\(side.label) viewed byte context copied. Includes original byte values."
        } else {
            errorMessage = "The system clipboard did not accept the byte context."
        }
    }

    func copyTextMatchDetails(_ search: FocusedStringSearch, side: ComparisonSide,
                              selectionID: UUID, to clipboard: NSPasteboard = .general) {
        guard focusedValue?.id == selectionID, !isWorking && !isTerminating,
              let text = search.copyText(side: side), text.utf8.count <= FocusedStringSearch.copyByteLimit else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(text.utf8), forType: .string) {
            status = "\(side.label) text match details copied. Includes complete scalar escapes and UTF-8 bytes."
        } else {
            errorMessage = "The system clipboard did not accept the text match details."
        }
    }

    func copyHexMatchDetails(_ search: FocusedHexSearch, side: ComparisonSide,
                             selectionID: UUID, to clipboard: NSPasteboard = .general) {
        guard focusedValue?.id == selectionID, !isWorking && !isTerminating,
              let text = search.copyText(side: side), text.utf8.count <= FocusedHexSearch.copyByteLimit else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(text.utf8), forType: .string) {
            status = "\(side.label) hex match details copied. Includes all matched original bytes."
        } else {
            errorMessage = "The system clipboard did not accept the hex match details."
        }
    }

    func copyDifferenceDetails(_ text: String?, selectionID: UUID, to clipboard: NSPasteboard = .general) {
        guard focusedValue?.id == selectionID, !isWorking && !isTerminating,
              let text, text.utf8.count <= CurrentDifferenceDetails.byteLimit else { return }
        clipboard.clearContents()
        if clipboard.setData(Data(text.utf8), forType: .string) {
            status = "Current difference details copied. Includes captured scalar or byte values."
        } else {
            errorMessage = "The system clipboard did not accept the difference details."
        }
    }

    func copyTreeResultDetails(_ session: TreeTextSearchSession, to clipboard: NSPasteboard = .general) {
        guard !isBusy, !session.running, session.comparisonRevision == model.reportRevision,
              session.selectionID == model.browser.selectedRow?.id,
              let key = model.browser.selectedRow?.key, let hit = session.selectedHit,
              let cursor = session.cursor else { return }
        do {
            let text = try TreeResultDetails.text(key: key, hit: hit, query: session.input.value,
                                                  complete: cursor.complete, limited: cursor.limited, scope: cursor.scope)
            clipboard.clearContents()
            if clipboard.setData(Data(text.utf8), forType: .string) {
                status = "Selected tree result details copied. Includes complete typed path and exact UTF-8 match."
            } else { errorMessage = "The system clipboard did not accept the tree result details." }
        } catch {
            errorMessage = "The complete tree result details exceed the 64 KiB copy limit. Clipboard unchanged."
        }
    }

    func openTreeHit(_ session: TreeTextSearchSession, hit: EntitlementTreeSearch.Hit) {
        guard !isBusy, !session.running, session.comparisonRevision == model.reportRevision,
              session.selectionID == model.browser.selectedRow?.id,
              session.cursor?.hits.contains(where: { $0.id == hit.id }) == true else { return }
        focusedValue = .init(entitlementKey: model.browser.selectedRow?.key ?? "",
                             pathPreview: hit.pathPreview,
                             previous: hit.side == .previous ? .string(hit.value) : nil,
                             current: hit.side == .current ? .string(hit.value) : nil,
                             initialSide: hit.side, initialScalar: hit.match.scalarOffset + 1,
                             initialMatchRange: hit.match.byteOffset..<(hit.match.byteOffset + hit.queryByteCount))
    }

    func copyTreeHexResultDetails(_ session: TreeHexSearchSession, to clipboard: NSPasteboard = .general) {
        guard !isBusy, !session.running, session.comparisonRevision == model.reportRevision,
              session.selectionID == model.browser.selectedRow?.id,
              let key = model.browser.selectedRow?.key, let hit = session.selectedHit,
              let cursor = session.cursor else { return }
        do {
            let text = try TreeHexResultDetails.text(key: key, hit: hit, query: session.input.value,
                                                  complete: cursor.complete, limited: cursor.limited, scope: cursor.scope)
            clipboard.clearContents()
            if clipboard.setData(Data(text.utf8), forType: .string) {
                status = "Selected tree hex result details copied. Includes complete typed path and exact matched bytes."
            } else { errorMessage = "The system clipboard did not accept the tree result details." }
        } catch {
            errorMessage = "The complete tree result details exceed the 64 KiB copy limit. Clipboard unchanged."
        }
    }

    func openTreeHexHit(_ session: TreeHexSearchSession, hit: EntitlementTreeHexSearch.Hit) {
        guard !isBusy, !session.running, session.comparisonRevision == model.reportRevision,
              session.selectionID == model.browser.selectedRow?.id,
              session.cursor?.hits.contains(where: { $0.id == hit.id }) == true else { return }
        focusedValue = .init(entitlementKey: model.browser.selectedRow?.key ?? "",
                             pathPreview: hit.pathPreview,
                             previous: hit.side == .previous ? .data(hit.value) : nil,
                             current: hit.side == .current ? .data(hit.value) : nil,
                             initialSide: hit.side, initialByte: hit.byteOffset + 1)
    }
}
