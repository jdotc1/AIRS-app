import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import AIRSCore
import AIRSEntitlements
import enum EntitlementDiffCore.ReportDestination

enum WorkspaceSelection: Hashable {
    case overview
    case finding(String)
}

enum VerdictFilter: String, CaseIterable, Identifiable {
    case all, agreement, inconsistency, unresolved
    var id: String { rawValue }
    var title: String {
        if self == .all { return "All verdicts" }
        return AuditVerdict(rawValue: rawValue)?.title ?? rawValue
    }
    func includes(_ verdict: AuditVerdict) -> Bool {
        self == .all || rawValue == verdict.rawValue
    }
}

struct ComparisonDocument: Identifiable, Sendable {
    let id = UUID()
    let report: ComparisonReport
    let data: Data
    let formattedJSON: String
    var protectedInputs: [URL] = []
}

private struct OpenedAudit: Sendable {
    let report: AuditReport
    let data: Data
}

private enum WorkspaceResult: Sendable {
    case audit(OpenedAudit, source: String, inspectedInput: URL?)
    case symbols(OpenedAudit, symbolInput: URL)
    case comparison(ComparisonDocument)
    case handoff(Data, filename: String)
    case boundRequest(BoundReviewRequest)
    case boundReceipts([BoundReviewReceiptEntry])
    case exported(String)
    case library([ReportLibraryEntry], message: String)
    case retained(OpenedAudit, provenance: LibraryProvenance)
    case batch(ImageBatchSnapshot)
    case batchHistory([BatchHistoryEntry])
    case removedBatch(UUID, [BatchHistoryEntry])
    case loadedBatch(ImageBatchSnapshot)
    case discovery(BundleDiscoveryResult)
    case batchPlan(BatchComparisonPlan)
    case batchComparison(BatchComparisonResult)
    case batchExport(Data, [URL])
}

/// File I/O and JSON decoding occur away from the main actor.
private actor DocumentWorker {
    let boundLedger: BoundReviewLedger
    init(boundLedger: BoundReviewLedger) { self.boundLedger = boundLedger }
    func boundRequest(_ data: Data, findingID: String) throws -> BoundReviewRequest {
        try BoundReviewRequest.create(report:data,findingID:findingID)
    }
    func exportBoundRequest(_ request: BoundReviewRequest,to url: URL) async throws {
        try Task.checkCancellation()
        // Retain before delivery so an exported request is always correlatable.
        // A failed external write may leave a prepared request, never a false acknowledgment.
        try await boundLedger.retain(request)
        try request.archiveBytes.write(to:url,options:.withoutOverwriting)
    }
    func retainBoundArchive(_ url: URL) async throws {
        _ = try await boundLedger.importArchive(BoundReviewFiles.read(url,limit:InspectionArchive.maximumBytes))
    }
    func importAcknowledgment(_ url: URL) async throws -> [BoundReviewReceiptEntry] {
        _ = try await boundLedger.importAcknowledgment(BoundReviewFiles.read(url,limit:1_048_576))
        return try await boundLedger.entries()
    }
    func acknowledgments() async throws -> [BoundReviewReceiptEntry] { try await boundLedger.entries() }

    func load(_ url: URL) throws -> OpenedAudit {
        let data = try ReportFiles.readBounded(url)
        return OpenedAudit(report: try AuditReport.decode(data), data: data)
    }

    func audit(_ data: Data) throws -> OpenedAudit {
        OpenedAudit(report: try AuditReport.decode(data), data: data)
    }

    func symbols(original: Data, enriched: Data) throws -> OpenedAudit {
        OpenedAudit(report: try ReportFiles.decodeSymbolEnrichment(original: original, enriched: enriched), data: enriched)
    }

    func comparison(_ data: Data) throws -> ComparisonDocument {
        ComparisonDocument(report: try ComparisonReport.decode(data), data: data,
                           formattedJSON: try ReportFiles.prettyJSON(data))
    }

    func batchExport(_ result: BatchComparisonResult) throws -> Data { try result.exportData() }

    func validateHandoff(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? Int == 1,
              object["report_kind"] as? String == "airs.macscope_handoff",
              object["integration_status"] as? String == "proposed_export_contract" else {
            throw ReportError.invalidContents("Unsupported MacScope handoff format.")
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class AuditWorkspace: ObservableObject {
    @Published private(set) var report: AuditReport?
    private(set) var reportRevision = UUID()
    @Published private(set) var sourceLabel = ""
    @Published private(set) var isBusy = false
    @Published private(set) var canCancel = false
    @Published private(set) var status = "Open a binary, app bundle, or audit report."
    @Published private(set) var setupMessage: String?
    @Published var selection: WorkspaceSelection? = .overview
    @Published var search = ""
    @Published var verdictFilter: VerdictFilter = .all
    @Published var boundReviewReceipts: [BoundReviewReceiptEntry]?
    @Published var showingError = false
    @Published private(set) var errorMessage = ""
    @Published var bundleDiscovery: BundleDiscoveryResult?
    @Published var batchComparisonPlan: BatchComparisonPlan?
    @Published private(set) var batchComparisonResult: BatchComparisonResult?
    @Published var comparisonDocument: ComparisonDocument?
    @Published var showingLibrary = false
    @Published var showingBatch = false
    @Published var showingBatchHistory = false
    @Published var projectHistoryIDs:[UUID:[UUID]]=[:]
    var projectProtectedInputs:[URL]=[]
    @Published private(set) var batchHistoryEntries: [BatchHistoryEntry] = []
    @Published private(set) var batchSnapshot: ImageBatchSnapshot?
    @Published private(set) var libraryEntries: [ReportLibraryEntry] = []
    @Published private(set) var recentReports: [URL] = []
    @Published private(set) var engineRuntimeLabel = ""
    @Published var reusesRetainedAnalyses = false
    @Published var usesExternalPython = false {
        didSet {
            preferences.set(usesExternalPython, forKey: "usesExternalPython")
            refreshEngineAvailability()
        }
    }
    @Published var pythonPath: String {
        didSet {
            preferences.set(pythonPath, forKey: "pythonExecutablePath")
            refreshEngineAvailability()
        }
    }

    let storageLocations: AuditWorkspaceStorageLocations
    private let preferences: UserDefaults
    private let runner = EngineRunner()
    private let documents: DocumentWorker
    private let library: ReportLibrary
    private let analysisReuse: AnalysisReuse
    private let recents: any WorkspaceRecentsRecording
    private let batches = ImageBatchRunner()
    private let batchComparisons = BatchComparisonRunner()
    private let history: BatchHistory
    private let batchCompare: (@Sendable (Data, Data) async throws -> Data)?
    private let batchAudit: (@Sendable (URL) async throws -> Data)?
    private var batchID: UUID?
    private var rawReport: Data?
    private var inspectedInput: URL?
    private var currentBundleProvenance: BundleImageProvenance?
    private var discoveredBundleInput: URL?
    private var attachedSymbolInput: URL?
    private var activeTask: Task<Void, Never>?
    private var operationID = UUID()
    private var terminationRequested = false
    private var exportFailedDuringQuit = false

    init(library: ReportLibrary? = nil, recents: (any WorkspaceRecentsRecording)? = nil,
         batchAudit: (@Sendable (URL) async throws -> Data)? = nil, batchHistory: BatchHistory? = nil,
         batchCompare: (@Sendable (Data, Data) async throws -> Data)? = nil,
         boundReviewLedger: BoundReviewLedger? = nil,
         supportRoot: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let support = supportRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let locations = AuditWorkspaceStorageLocations(supportRoot: support)
        self.storageLocations = locations
        self.documents = DocumentWorker(boundLedger:boundReviewLedger ?? BoundReviewLedger(root:locations.boundReviews))
        self.library = library ?? ReportLibrary(root: locations.reportLibrary)
        self.analysisReuse = AnalysisReuse(root: locations.analysisReuse, library: self.library)
        self.recents = recents ?? SystemDocumentRecents()
        self.batchCompare = batchCompare
        self.batchAudit = batchAudit
        self.history = batchHistory ?? BatchHistory(root: locations.batchHistory)
        usesExternalPython = preferences.bool(forKey: "usesExternalPython")
        pythonPath = preferences.string(forKey: "pythonExecutablePath") ?? ""
        recentReports = self.recents.recentDocumentURLs.filter { $0.pathExtension.lowercased() == "json" }
        refreshEngineAvailability()
    }

    var visibleFindings: [Finding] {
        report?.findings.filter { verdictFilter.includes($0.verdict) && $0.matches(search) } ?? []
    }

    var selectedFinding: Finding? {
        guard case .finding(let id)? = selection else { return nil }
        return report?.findings.first { $0.id == id }
    }

    var selectedFindingIsHidden: Bool {
        guard let finding = selectedFinding else { return false }
        return !verdictFilter.includes(finding.verdict) || !finding.matches(search)
    }

    /// Reveal the same finding; filtering never replaces its evidence or report.
    func revealSelectedFinding() {
        guard selectedFindingIsHidden else { return }
        search = ""
        verdictFilter = .all
    }

    var hasUnretainedBatchReports: Bool { batchSnapshot?.hasUnretainedReports == true }
    var hasUnsavedBatchHistory: Bool { batchSnapshot?.persistenceError != nil }
    var requiresQuitSettlement: Bool { isBusy || hasUnsavedBatchHistory }
    var blocksFileOpen: Bool {
        blocksWorkspaceNavigation || hasUnsavedBatchHistory
    }
    var blocksWorkspaceNavigation: Bool {
        isBusy || terminationRequested || showingError ||
        bundleDiscovery != nil || batchComparisonPlan != nil || comparisonDocument != nil || boundReviewReceipts != nil
    }
    var canResumeBatch: Bool {
        guard let snapshot = batchSnapshot, !isBusy, !hasUnretainedBatchReports, !hasUnsavedBatchHistory,
              !snapshot.items.contains(where: { $0.status == .running }) else { return false }
        return snapshot.items.contains { [.queued, .cancelled, .notStarted].contains($0.status) }
    }

    func chooseBundleDiscovery() {
        guard !isBusy, !hasUnsavedBatchHistory else { return }
        let panel = NSOpenPanel()
        panel.title = "Discover App Images"
        panel.message = "Choose one owned .app. Review a bounded inventory before explicitly selecting up to 16 images for analysis. No image runs during discovery."
        panel.prompt = "Discover"
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        discoverBundle(url)
    }

    func discoverBundle(_ url: URL) {
        guard !isBusy, !hasUnsavedBatchHistory else { return }
        perform("Discovering bounded app image candidates…", acceptsCancelledResult: true) {
            .discovery(try BundleDiscovery().discover(url))
        }
    }

    func analyzeDiscoveredImages(_ selected: Set<UUID>) {
        guard !isBusy, let inventory = bundleDiscovery else { return }
        let rows = inventory.entries.filter { selected.contains($0.id) && $0.selectable }
        guard !rows.isEmpty, rows.count <= ImageBatchRunner.maximumImages, rows.count == selected.count else {
            present(ReportError.invalidContents("Select between 1 and 16 captured image candidates.")); return
        }
        var provenance: [URL: BundleImageProvenance] = [:]
        for row in rows { if let image = row.provenance { provenance[image.bundle.appendingPathComponent(image.relativePath)] = image } }
        // Keep each discovery-bound identity; the runner reports changed entries individually.
        executeBatch(rows.compactMap { $0.provenance.map { $0.bundle.appendingPathComponent($0.relativePath) } }, resuming: nil, bundleImages: provenance)
        if isBusy { bundleDiscovery = nil }
    }

    func chooseBatch() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Analyze Selected Images"
        panel.message = "Select up to 16 files or .app bundles. One image runs at a time; completed raw reports are kept in Report Library. App bundles contribute only their principal executable."
        panel.prompt = "Analyze Batch"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        startBatch(panel.urls)
    }

    func showBatchResults() {
        showingBatchHistory = false
        showingLibrary = false
        showingBatch = true
    }

    func startBatch(_ inputs: [URL]) {
        executeBatch(inputs, resuming: nil)
    }

    func resumeBatch() {
        guard canResumeBatch, let previous = batchSnapshot else { return }
        executeBatch(previous.items.map(\.input), resuming: previous)
    }

    private func executeBatch(_ inputs: [URL], resuming previous: ImageBatchSnapshot?, bundleImages: [URL: BundleImageProvenance] = [:]) {
        guard !isBusy, !terminationRequested else { return }
        guard !hasUnsavedBatchHistory else {
            present(ReportError.invalidContents("Save the pending batch checkpoint before starting or loading another batch."))
            return
        }
        guard !inputs.isEmpty, inputs.count <= ImageBatchRunner.maximumImages else {
            present(ReportError.invalidContents("Select between 1 and 16 images. No images were started."))
            return
        }
        do {
            let audit: @Sendable (URL) async throws -> Data
            var configuration: EngineConfiguration?
            if let batchAudit { audit = batchAudit }
            else {
                let resolved = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
                configuration = resolved
                audit = { [runner] input in
                    try await runner.run(.audit(input: input), configuration: resolved).data
                }
            }
            let id = UUID()
            batchID = id
            showingBatchHistory = false
            showingLibrary = false
            showingBatch = true
            batchSnapshot = previous
            let resolvedConfiguration = configuration
            let useReuse = reusesRetainedAnalyses
            perform(previous == nil ? "Starting selected-image batch…" : "Resuming remaining images…", acceptsCancelledResult: true) { [weak self, batches, library, history, analysisReuse] in
                let persistentID = previous?.id ?? id
                try await history.acquire(persistentID, expecting: previous.map { Set([$0.executionID]) }, revision: previous?.checkpointRevision)
                do {
                let recovered: ImageBatchSnapshot?
                if let previous { recovered = try await history.load(previous.id) }
                else { recovered = nil }
                let context = try resolvedConfiguration.map { try BatchExecutionContext.capture($0) }
                let snapshot = try await batches.run(inputs: inputs, id: id, resuming: recovered, context: context, bundleImages: bundleImages, audit: { input in
                    var before: AnalysisReuse.Ticket?
                    if useReuse, let configuration = resolvedConfiguration {
                        before = try? await analysisReuse.ticket(input: input, configuration: configuration)
                    }
                    let data = try await audit(input)
                    if let configuration = resolvedConfiguration, let before {
                        _ = try? await analysisReuse.enroll(data, input: input, configuration: configuration, before: before,
                            provenance: LibraryProvenance(sourceLabel: "Batch analysis of \(input.path)", inspectedInput: input,
                                bundleImage: recovered?.items.first(where: { $0.input == input })?.bundleImage ?? bundleImages[input]))
                    }
                    return data
                }, reuse: { input in
                    guard useReuse, let configuration = resolvedConfiguration,
                          let ticket = try? await analysisReuse.ticket(input: input, configuration: configuration) else { return nil }
                    return try? await analysisReuse.lookup(ticket, input: input, configuration: configuration)
                }, retain: { data, input in
                    try await library.keep(data, provenance: LibraryProvenance(
                        sourceLabel: "Batch analysis of \(input.path)", inspectedInput: input,
                        bundleImage: recovered?.items.first(where: { $0.input == input })?.bundleImage ?? bundleImages[input]))
                }, checkpoint: { snapshot in
                    try await history.save(snapshot)
                }, progress: { [weak self] snapshot in
                    await self?.receiveBatch(snapshot)
                })
                await history.release(persistentID)
                return .batch(snapshot)
                } catch { await history.release(persistentID); throw error }
            }
        } catch { present(error) }
    }

    private func receiveBatch(_ snapshot: ImageBatchSnapshot) {
        guard snapshot.executionID == batchID else { return }
        // Preserve completed/session bytes even while an ordinary Quit is settling.
        batchSnapshot = snapshot
        if !terminationRequested {
            let completed = snapshot.items.filter { $0.status == .completed }.count
            status = "Batch: \(completed) of \(snapshot.items.count) selected images completed\(snapshot.settled ? "." : "…")"
        }
    }

    func openBatchHistory() {
        guard !isBusy else { return }
        guard !hasUnsavedBatchHistory else {
            present(ReportError.invalidContents("Save the current batch checkpoint before changing history.")); return
        }
        showingBatchHistory = true
        showingBatch = false
        showingLibrary = false
        perform("Loading batch history…") { [history] in .batchHistory(try await history.entries()) }
    }

    func prepareBatchComparison(baseline: UUID, current: UUID) {
        guard !isBusy, !hasUnsavedBatchHistory else { return }
        perform("Opening saved batches for explicit pairing…") { [history] in
            let old = try await history.metadata(baseline)
            let new = try await history.metadata(current)
            return .batchPlan(try BatchComparisonPlan(baseline: old, current: new))
        }
    }

    func compareSavedBatches(_ pairs: [BatchImagePair]) {
        guard !isBusy, let plan = batchComparisonPlan else { return }
        do {
            try plan.validate(pairs)
            let configuration = batchCompare == nil ? try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython) : nil
            let injectedCompare = batchCompare
            batchComparisonResult = nil
            perform("Comparing explicitly paired saved reports…", acceptsCancelledResult: true) { [weak self, history, library, batchComparisons, runner] in
                let old = try await history.metadata(plan.baseline.id)
                let new = try await history.metadata(plan.current.id)
                guard old.checkpointRevision == plan.baseline.checkpointRevision,
                      new.checkpointRevision == plan.current.checkpointRevision,
                      old.executionID == plan.baseline.executionID, new.executionID == plan.current.executionID else {
                    throw ReportError.invalidContents("A saved batch changed. Reopen both batches and review pairing again.")
                }
                let result = try await batchComparisons.run(plan: plan, pairs: pairs,
                    load: { try await library.load($0) },
                    compare: { baseline, current in
                        if let injectedCompare { return try await injectedCompare(baseline, current) }
                        guard let configuration else { throw EngineError.busy }
                        return try await runner.run(.diff(baseline: baseline, current: current), configuration: configuration).data
                    }, progress: { [weak self] result in await self?.receiveBatchComparison(result) })
                return .batchComparison(result)
            }
        } catch { present(error) }
    }

    private func receiveBatchComparison(_ result: BatchComparisonResult) {
        guard batchComparisonPlan?.id == result.plan.id else { return }
        batchComparisonResult = result
    }

    func exportBatchComparison() {
        guard !isBusy, let result = batchComparisonResult, result.settled else { return }
        perform("Preparing batch comparison export…") { [documents] in
            .batchExport(try await documents.batchExport(result),
                (result.plan.baseline.items + result.plan.current.items).flatMap { [$0.input] + [$0.bundleImage?.bundle].compactMap { $0 } })
        }
    }

    func loadBatchHistory(_ id: UUID) {
        guard !isBusy, !hasUnsavedBatchHistory else { return }
        perform("Opening batch checkpoint…") { [history] in .loadedBatch(try await history.load(id)) }
    }

    func removeBatchHistory(_ id: UUID) {
        guard !isBusy, !hasUnsavedBatchHistory else { return }
        perform("Moving batch history to Trash…", cancellable: false) { [history] in
            try await history.remove(id)
            return .removedBatch(id, try await history.entries())
        }
    }

    func saveBatchHistory() {
        guard !isBusy, var snapshot = batchSnapshot else { return }
        snapshot.persistenceError = nil
        let saved = snapshot
        perform("Saving batch checkpoint…", cancellable: false) { [history] in
            var updated = saved
            updated.checkpointRevision = try await history.save(saved)
            return .batch(updated)
        }
    }

    func openBatchReport(_ item: ImageBatchItem) {
        guard !isBusy else { return }
        if let id = item.retainedReportID { openRetainedReport(id) }
        else if let data = item.unretainedData {
            perform("Opening completed session report…") { [documents] in
                .retained(try await documents.audit(data), provenance: LibraryProvenance(
                    sourceLabel: "Batch analysis of \(item.input.path)", inspectedInput: item.input, bundleImage: item.bundleImage))
            }
        }
    }

    func retryBatchRetention(_ item: ImageBatchItem) {
        guard !isBusy, let data = item.unretainedData, let snapshot = batchSnapshot,
              let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else { return }
        perform("Keeping completed batch report…", cancellable: false) { [library, history] in
            try await history.acquire(snapshot.id, expecting: Set([snapshot.executionID] + [snapshot.previousExecutionID].compactMap { $0 }), revision: snapshot.checkpointRevision)
            do {
            let id = try await library.keep(data, provenance: LibraryProvenance(
                sourceLabel: "Batch analysis of \(item.input.path)", inspectedInput: item.input, bundleImage: item.bundleImage))
            var updated = snapshot
            updated.items[index].retainedReportID = id
            updated.items[index].unretainedData = nil
            updated.items[index].message = "Original report retained in library."
            do { updated.checkpointRevision = try await history.save(updated); updated.persistenceError = nil }
            catch { updated.persistenceError = error.localizedDescription }
            await history.release(snapshot.id)
            return .batch(updated)
            } catch { await history.release(snapshot.id); throw error }
        }
    }

    func discardBatchSessionCopy(_ id: UUID) {
        guard !isBusy, let index = batchSnapshot?.items.firstIndex(where: { $0.id == id }),
              batchSnapshot?.items[index].unretainedData != nil else { return }
        batchSnapshot?.items[index].unretainedData = nil
        batchSnapshot?.items[index].message = "Unretained session copy explicitly discarded. No saved report is available."
        batchSnapshot?.persistenceError = "Discard must be committed to batch history."
        saveBatchHistory()
    }

    func refreshEngineAvailability() {
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            engineRuntimeLabel = configuration.isBundled ? "Private Python 3.15.0 · no separate interpreter required" : "External development interpreter"
            setupMessage = nil
        } catch {
            engineRuntimeLabel = "Runtime unavailable"
            setupMessage = error.localizedDescription
        }
    }

    func chooseBinary() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Binary or App"
        panel.message = "Choose a final Mach-O binary or a macOS .app bundle to read locally."
        panel.prompt = "Analyze"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSelectedBinaryOrApp(url)
    }

    /// The binary picker can select a debug companion; retain the existing
    /// identity-gated attachment workflow instead of auditing its DWARF image.
    func openSelectedBinaryOrApp(_ url: URL) {
        guard !isBusy else { return }
        if isDSYMSelection(url) {
            guard rawReport != nil else {
                let guidance = "Open the matching binary or audit report first, then attach this dSYM."
                errorMessage = guidance
                status = guidance
                showingError = true
                return
            }
            attachDSYM(url)
            return
        }
        analyze(url)
    }

    private func isDSYMSelection(_ url: URL) -> Bool {
        if url.pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame { return true }
        let dwarfDirectory = url.deletingLastPathComponent()
        guard dwarfDirectory.lastPathComponent == "DWARF",
              dwarfDirectory.deletingLastPathComponent().lastPathComponent == "Resources",
              dwarfDirectory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            return false
        }
        return dwarfDirectory.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .pathExtension.caseInsensitiveCompare("dSYM") == .orderedSame
    }

    func analyze(_ url: URL) {
        guard !isBusy else { return }
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            let useReuse = reusesRetainedAnalyses
            perform("Checking saved analysis / analyzing \(url.lastPathComponent)…") { [runner, documents, analysisReuse] in
                let before = useReuse ? try? await analysisReuse.ticket(input: url, configuration: configuration) : nil
                if let before, let hit = try? await analysisReuse.lookup(before, input: url, configuration: configuration) {
                    let document = try await documents.audit(hit.data)
                    return .audit(document, source: "Reused analysis from \(hit.generatedAt.formatted()) · \(url.lastPathComponent)", inspectedInput: url)
                }
                let artifact = try await runner.run(.audit(input: url), configuration: configuration)
                let document = try await documents.audit(artifact.data)
                var retention = ""
                if let before {
                    let id = try? await analysisReuse.enroll(artifact.data, input: url, configuration: configuration, before: before,
                        provenance: LibraryProvenance(sourceLabel: "Analysis of \(url.lastPathComponent)", inspectedInput: url))
                    retention = id == nil ? " · saved reuse unavailable" : " · retained for reuse"
                }
                return .audit(document, source: "Analysis of \(url.lastPathComponent)" + retention, inspectedInput: url)
            }
        } catch { present(error) }
    }

    func chooseReport() {
        guard !isBusy, let url = chooseJSON(title: "Open Audit Report", prompt: "Open") else { return }
        importReport(url)
    }

    func importReport(_ url: URL) {
        guard !isBusy else { return }
        perform("Opening \(url.lastPathComponent)…") { [documents] in
            let document = try await documents.load(url)
            return .retained(document, provenance: LibraryProvenance(sourceLabel: "Imported \(url.path)"))
        }
        // Record only after successful import, not when the open operation begins.
        pendingRecentReport = url
    }

    private var pendingRecentReport: URL?

    /// The shared opener has already validated these original bytes off MainActor.
    func openValidatedReport(_ report: AuditReport, data: Data, from url: URL) {
        guard !blocksFileOpen else { return }
        pendingRecentReport = url
        apply(.retained(OpenedAudit(report: report, data: data),
                        provenance: LibraryProvenance(sourceLabel: "Imported \(url.path)")))
    }

    func clearRecentReports() {
        guard !isBusy else { return }
        recents.clearRecentDocuments()
        recentReports = []
    }

    func openLibrary() {
        guard !isBusy else { return }
        showingLibrary = true
        showingBatch = false
        showingBatchHistory = false
        refreshLibrary()
    }

    func refreshLibrary() {
        perform("Loading report library…") { [library] in
            .library(try await library.entries(), message: "Report library ready.")
        }
    }

    func keepCurrentReport() {
        guard let data = rawReport, !isBusy else { return }
        let provenance = LibraryProvenance(sourceLabel: sourceLabel,
            inspectedInput: inspectedInput, symbolInput: attachedSymbolInput, bundleImage: currentBundleProvenance)
        perform("Keeping report…", cancellable: false) { [library] in
            _ = try await library.keep(data, provenance: provenance)
            return .library(try await library.entries(), message: "Report kept in library. Original bytes preserved.")
        }
    }

    func openRetainedReport(_ id: UUID) {
        perform("Opening retained report…") { [library] in
            let retained = try await library.load(id)
            return .retained(OpenedAudit(report: retained.report, data: retained.data), provenance: retained.provenance)
        }
    }

    func compareRetainedReport(_ id: UUID) {
        guard !isBusy, let currentData = rawReport else { return }
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            perform("Comparing retained baseline…") { [library, runner, documents] in
                let baseline = try await library.load(id)
                try Task.checkCancellation()
                let artifact = try await runner.run(.diff(baseline: baseline.data, current: currentData), configuration: configuration)
                var document = try await documents.comparison(artifact.data)
                document.protectedInputs = [baseline.provenance.inspectedInput, baseline.provenance.symbolInput, baseline.provenance.bundleImage?.bundle].compactMap { $0 }
                return .comparison(document)
            }
        } catch { present(error) }
    }

    func removeRetainedReport(_ id: UUID) {
        perform("Moving retained copy to Trash…", cancellable: false) { [library] in
            try await library.remove(id)
            return .library(try await library.entries(), message: "Retained copy moved to Trash. Current report and original files remain available.")
        }
    }

    func chooseBaseline() {
        guard !isBusy, let currentData = rawReport,
              let url = chooseJSON(title: "Choose Baseline Audit Report", prompt: "Compare") else { return }
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            perform("Comparing with \(url.lastPathComponent)…") { [runner, documents] in
                let baseline = try await documents.load(url)
                try Task.checkCancellation()
                let artifact = try await runner.run(
                    .diff(baseline: baseline.data, current: currentData),
                    configuration: configuration
                )
                return .comparison(try await documents.comparison(artifact.data))
            }
        } catch { present(error) }
    }

    func chooseDSYM() {
        guard !isBusy, rawReport != nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach dSYM"
        panel.message = "Choose a companion dSYM bundle or its DWARF file. UUID and exact architecture must match the current report."
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachDSYM(url)
    }

    func attachDSYM(_ url: URL) {
        guard !isBusy, let data = rawReport else { return }
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            perform("Attaching \(url.lastPathComponent)…") { [runner, documents] in
                let artifact = try await runner.run(.symbols(report: data, dsym: url), configuration: configuration)
                let document = try await documents.symbols(original: data, enriched: artifact.data)
                return .symbols(document, symbolInput: url)
            }
        } catch { present(error) }
    }

    func exportCurrentReport() {
        guard let data = rawReport, let report else { return }
        saveJSON(data, suggestedFilename: "\(safeFilename(report.image.displayName))-audit.json")
    }

    func exportComparison(_ document: ComparisonDocument) {
        saveJSON(document.data, suggestedFilename: "airs-comparison.json", protectedInputs: document.protectedInputs)
    }

    func exportHandoff(_ finding: Finding) {
        guard !isBusy, let data = rawReport else { return }
        do {
            let configuration = try EngineConfiguration.resolve(pythonSetting: pythonPath, useExternalPython: usesExternalPython)
            let filename = "\(safeFilename(finding.displayName))-handoff.json"
            perform("Preparing handoff for \(finding.displayName)…") { [runner, documents] in
                let artifact = try await runner.run(
                    .handoff(report: data, findingID: finding.id),
                    configuration: configuration
                )
                try await documents.validateHandoff(artifact.data)
                return .handoff(artifact.data, filename: filename)
            }
        } catch { present(error) }
    }

    func exportBoundRequest(_ finding: Finding) {
        guard !isBusy,let data = rawReport else { return }
        perform("Preparing bound review…") { [documents] in
            .boundRequest(try await documents.boundRequest(data,findingID:finding.id))
        }
    }

    func chooseConsumerAcknowledgment() {
        guard !isBusy,let url = chooseJSON(title:"Import Consumer Acknowledgment",prompt:"Import") else { return }
        importConsumerAcknowledgment(url)
    }

    @discardableResult
    func importConsumerAcknowledgment(_ url: URL) -> Task<Void,Never>? {
        perform("Importing consumer acknowledgment…",cancellable:false) { [documents] in
            .boundReceipts(try await documents.importAcknowledgment(url))
        }
        return activeTask
    }

    @discardableResult
    func reviewConsumerAcknowledgments() -> Task<Void,Never>? {
        perform("Loading consumer acknowledgments…") { [documents] in
            .boundReceipts(try await documents.acknowledgments())
        }
        return activeTask
    }

    func chooseBoundRequestArchive() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Retain Bound Request Archive"
        panel.message = "Retain an AIRS bound request to associate its exact consumer receipts. This does not navigate or launch MacScope."
        panel.allowedContentTypes = [UTType(filenameExtension:"airsreview") ?? .json,.json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,let url = panel.url else { return }
        perform("Retaining bound request…",cancellable:false) { [documents] in
            try await documents.retainBoundArchive(url)
            return .boundReceipts(try await documents.acknowledgments())
        }
    }

    private func saveBoundRequest(_ request: BoundReviewRequest) {
        let panel = NSSavePanel()
        panel.title = "Export Bound Review Request"
        panel.message = "Contains the original report and selected finding. Requires a future bound-protocol consumer; current manual-v1 import remains separate. Choose a new file."
        panel.allowedContentTypes = [UTType(filenameExtension:"airsreview") ?? .json]
        panel.nameFieldStringValue = "airs-bound-review.airsreview"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try validateExportDestination(url,protectedInputs:[]) } catch { present(error); return }
        perform("Exporting bound review…",cancellable:false) { [documents] in
            try await documents.exportBoundRequest(request,to:url)
            return .exported(url.lastPathComponent)
        }
    }

    func cancel() {
        guard isBusy, canCancel else { return }
        status = "Cancelling…"
        activeTask?.cancel()
        // The runner's cancellation handler owns termination and cleanup.
    }

    func finishBeforeQuit() async -> Bool {
        terminationRequested = true
        let pendingTask = activeTask
        if canCancel { pendingTask?.cancel() }
        await pendingTask?.value
        if hasUnsavedBatchHistory {
            terminationRequested = false
            exportFailedDuringQuit = false
            showingLibrary = false
            showingBatch = true
            present(ReportError.invalidContents("The batch checkpoint could not be saved. Use Save Checkpoint in Batch Results before quitting; current outcomes and any completed session report remain available."))
            return false
        }
        if exportFailedDuringQuit {
            terminationRequested = false
            exportFailedDuringQuit = false
            return false
        }
        return true
    }

    func choosePython() {
        let panel = NSOpenPanel()
        panel.title = "Choose Python 3.11 or Newer"
        panel.message = "Choose the local Python executable, for example /opt/homebrew/bin/python3."
        panel.prompt = "Use Python"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { usesExternalPython = true; pythonPath = url.path }
    }

    private func chooseJSON(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func saveJSON(_ data: Data, suggestedFilename: String, protectedInputs: [URL] = []) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Export JSON"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try validateExportDestination(url, protectedInputs: protectedInputs) }
        catch { present(error); return }

        exportJSON(data, to: url)
    }

    func validateExportDestination(_ url: URL, protectedInputs: [URL]) throws {
        if !projectProtectedInputs.isEmpty {try ReportDestination.validate(url,excluding:projectProtectedInputs)}
        for input in [inspectedInput, attachedSymbolInput, discoveredBundleInput].compactMap({ $0 }) + protectedInputs {
            let protectedPath = input.resolvingSymlinksInPath().standardizedFileURL.path
            let destinationPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let isInsideBundle = ["app", "dsym"].contains(input.pathExtension.lowercased())
                && destinationPath.hasPrefix(protectedPath + "/")
            if destinationPath == protectedPath || isInsideBundle {
                throw ReportError.invalidContents("Choose a JSON destination outside the inspected images and attached debug artifacts.")
            }
        }
    }

    // Shared by the save panel and native lifecycle tests.
    func exportJSON(_ data: Data, to url: URL) {
        // Once the user chooses a destination, the atomic commit reports its real result.
        perform("Exporting \(url.lastPathComponent)…", cancellable: false) { [documents] in
            try await documents.write(data, to: url)
            return .exported(url.lastPathComponent)
        }
    }

    private func perform(
        _ label: String,
        cancellable: Bool = true,
        acceptsCancelledResult: Bool = false,
        operation: @escaping @Sendable () async throws -> WorkspaceResult
    ) {
        guard !isBusy, !terminationRequested else { return }
        let token = UUID()
        operationID = token
        isBusy = true
        canCancel = cancellable
        status = label
        activeTask = Task { [weak self] in
            do {
                let result = try await operation()
                if cancellable && !acceptsCancelledResult { try Task.checkCancellation() }
                guard let self, self.operationID == token else { return }
                self.isBusy = false
                self.canCancel = false
                self.activeTask = nil
                if case .batch(let snapshot) = result { self.receiveBatch(snapshot) }
                guard !self.terminationRequested else { return }
                self.apply(result)
            } catch {
                guard let self, self.operationID == token else { return }
                self.isBusy = false
                self.canCancel = false
                self.activeTask = nil
                if self.terminationRequested {
                    guard !cancellable else { return }
                    self.exportFailedDuringQuit = true
                }
                if error is CancellationError {
                    self.status = self.report == nil ? "Cancelled."
                        : "Cancelled. The previously opened report remains available."
                } else {
                    self.status = "The operation could not finish."
                    self.present(error)
                }
                self.pendingRecentReport = nil
                self.batchID = self.batchSnapshot?.executionID
                if self.batchSnapshot == nil { self.showingBatch = false }
            }
        }
    }

    private func apply(_ result: WorkspaceResult) {
        switch result {
        case .audit(let document, let source, let inspectedInput):
            reportRevision = UUID()
            showingBatchHistory = false
            showingBatch = false
            showingLibrary = false
            report = document.report
            rawReport = document.data
            self.inspectedInput = inspectedInput
            attachedSymbolInput = nil
            discoveredBundleInput = nil
            currentBundleProvenance = nil
            sourceLabel = source
            selection = .overview
            search = ""
            verdictFilter = .all
            comparisonDocument = nil
            status = "\(document.report.summary.functionCount) functions in report · " +
                "\(document.report.summary.checkedPCCount) modeled PC observations"
        case .symbols(let document, let symbolInput):
            reportRevision = UUID()
            showingBatchHistory = false
            showingBatch = false
            showingLibrary = false
            report = document.report
            rawReport = document.data
            attachedSymbolInput = symbolInput
            status = document.report.sourceAnnotations?.message ?? "Symbol attachment completed."
        case .comparison(let document):
            showingBatchHistory = false
            showingBatch = false
            showingLibrary = false
            comparisonDocument = document
            status = "Baseline comparison ready."
        case .boundRequest(let request):
            status = "Bound request prepared; choose a new export file."
            saveBoundRequest(request)
        case .boundReceipts(let entries):
            boundReviewReceipts = entries
            status = "Consumer acknowledgments loaded as imported evidence; recovery semantics remain source-reported."
        case .handoff(let data, let filename):
            status = "Handoff JSON is ready to export."
            saveJSON(data, suggestedFilename: filename)
        case .exported(let filename):
            status = "Exported \(filename)."
        case .library(let entries, let message):
            libraryEntries = entries
            status = message
        case .retained(let document, let provenance):
            apply(.audit(document, source: provenance.sourceLabel, inspectedInput: provenance.inspectedInput))
            attachedSymbolInput = provenance.symbolInput
            discoveredBundleInput = provenance.bundleImage?.bundle
            currentBundleProvenance = provenance.bundleImage
            showingLibrary = false
            if let url = pendingRecentReport {
                recents.noteRecentDocument(url)
                recentReports = recents.recentDocumentURLs.filter { $0.pathExtension.lowercased() == "json" }
                pendingRecentReport = nil
            }
        case .batch(let snapshot):
            receiveBatch(snapshot)
            showingLibrary = false
            showingBatch = true
            showingBatchHistory = false
        case .batchHistory(let entries):
            batchHistoryEntries = entries
            status = "Batch history ready. Remove moves only its checkpoint and pending recovery copy to Trash."
        case .removedBatch(let id, let entries):
            batchHistoryEntries = entries
            if batchSnapshot?.id == id { batchSnapshot = nil; batchID = nil }
            status = "Batch history moved to Trash. Reports in Report Library remain available."
        case .discovery(let inventory):
            bundleDiscovery = inventory
            status = inventory.partial ? "Partial app inventory ready; review limits and skips before selection." : "App code-location inventory ready for explicit selection."
        case .batchPlan(let plan):
            batchComparisonResult = nil
            batchComparisonPlan = plan
            status = "Confirm image pairings before comparison."
        case .batchComparison(let result):
            receiveBatchComparison(result)
            status = result.cancelled ? "Batch comparison cancelled; completed comparisons remain available." : "Saved-batch comparison ready."
        case .batchExport(let data, let inputs):
            saveJSON(data, suggestedFilename: "airs-batch-comparison.json", protectedInputs: inputs)
        case .loadedBatch(let snapshot):
            batchID = snapshot.executionID
            batchSnapshot = snapshot
            showingBatchHistory = false
            showingLibrary = false
            showingBatch = true
            status = "Saved batch opened. Resume is explicit; completed and failed images are not retried."
        }
    }

    private func present(_ error: Error) {
        if error is DecodingError {
            errorMessage = "The JSON does not match the expected AIRS report format. " +
                "\(error.localizedDescription)"
        } else {
            errorMessage = error.localizedDescription
        }
        showingError = true
        refreshEngineAvailability()
    }

    private func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\n\r\t")
        let parts = name.components(separatedBy: forbidden)
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? "airs" : String(joined.prefix(100))
    }
}


/// Shared path construction keeps the settings-review injection complete.
struct AuditWorkspaceStorageLocations {
    let boundReviews: URL
    let reportLibrary: URL
    let analysisReuse: URL
    let batchHistory: URL

    init(supportRoot: URL) {
        boundReviews = supportRoot.appendingPathComponent("AIRS/BoundReviews", isDirectory: true)
        reportLibrary = supportRoot.appendingPathComponent("AIRS/ReportLibrary", isDirectory: true)
        analysisReuse = supportRoot.appendingPathComponent("AIRS/AnalysisReuse", isDirectory: true)
        batchHistory = supportRoot.appendingPathComponent("AIRS/BatchHistory", isDirectory: true)
    }
}
