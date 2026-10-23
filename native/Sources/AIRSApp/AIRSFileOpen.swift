import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import AIRSCore
import AIRSEntitlements
import EntitlementDiffCore

/// Routing reads only the envelope; original bytes go to the existing validators.
enum AIRSOpenedReport: Sendable {
    case audit(AuditReport, Data)
    case entitlements(SavedReport)
    case inspection(InspectionDocument, Data)
    case archive(InspectionArchive, Data)
    case inventory(ComponentInventory, Data)
    case componentReview(ComponentReview)
    case assessments(AssessmentDocument)

    private struct Envelope: Decodable {
        enum Keys: String, CodingKey { case schema_version, report_kind, schemaVersion, tool, kind }
        let kind: Kind
        enum Kind { case audit, entitlements, inspection, archive, inventory }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Keys.self)
            let audit = fields.contains(.schema_version) || fields.contains(.report_kind)
            let inspection = fields.contains(.kind)
            let entitlements = fields.contains(.tool) || (fields.contains(.schemaVersion) && !inspection)
            if inspection {
                let name = try fields.decode(String.self, forKey: .kind)
                guard !audit, !entitlements,
                      [InspectionDocument.kind, InspectionArchive.kind, ComponentInventoryDocumentCodec.kind].contains(name) else {
                    throw ReportError.invalidContents("Unrecognized or ambiguous inspection document.")
                }
                kind = name == InspectionArchive.kind ? .archive : (name == ComponentInventoryDocumentCodec.kind ? .inventory : .inspection)
                return
            }
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
        case .inventory: return .inventory(try ComponentInventoryDocumentCodec.decode(data), data)
        case .archive: return .archive(try InspectionArchive.decode(data), data)
        case .inspection: return .inspection(try InspectionDocumentCodec.decode(data), data)
        case .audit: return .audit(try AuditReport.decode(data), data)
        case .entitlements: return .entitlements(try SavedReport.parse(data))
        }
    }

    static func attachment(_ archive: InspectionArchive, id: UUID) throws -> Self {
        guard try archive.validation(for: id) == .supported,
              let item = archive.attachments.first(where: { $0.id == id }) else {
            throw ReportError.invalidContents("This attachment is uninterpreted and cannot be opened as a supported report.")
        }
        if item.kind == AssessmentDocument.kind { return .assessments(try AssessmentDocument.decode(item.bytes)) }
        if item.kind == ComponentReviewArchive.kind { return .componentReview(try ComponentReviewArchive.decode(archive)) }
        return try parse(item.bytes)
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
    var intakeReview: AppIntakeReview?
    var archiveReview: ArchiveReview?
    var inventoryReview: ComponentInventoryReview?
    var projectReview:ProjectReviewSession?
    private(set) var projectStore:InspectionProjectStore
    var portableProjectPreview: PortableProjectPreview?
    var settledProjectExportPreview:SettledProjectExportPreview?
    var hasPortableProjectPreview:Bool {portableProjectPreview != nil || settledProjectExportPreview != nil}
    private var settledExportGeneration=UUID()
    private let settledExportWrite:@Sendable (SettledProjectExportPreview,URL) async throws -> Void
    private var portablePreviewGeneration = UUID()
    var importedProjectHistory: ImportedProjectHistorySnapshot?
    private var originalProjectContext: (store:InspectionProjectStore, selected:UUID?, history:ImportedProjectHistorySnapshot?)?
    var canReturnToOriginalProjectStore: Bool { originalProjectContext != nil }
    private let portableExport: @Sendable (InspectionProjectStore,UUID,Int,URL) async throws -> Void
    private let portableReconstruct: @Sendable (PortableProjectAdmission,URL) async throws -> InspectionProjectStore
    private let portableSettledReconstruct: @Sendable (PortableSettledBatchAdmission,URL) async throws -> InspectionProjectStore
    private var selectedProjectID:UUID?
    private var projectImports:[URL]=[]
    private var projectAssociationGeneration=UUID()
    var decodeInventoryError:String?
    var decodeInventoryReview:DecodeInventorySession?
    var coverageReview:CoverageReviewSession?
    var policyReview:PolicyReviewSession?
    var assessmentReview: AssessmentReviewSession?
    private let assessmentRunner: AssessmentRunner
    var componentReview: ComponentReviewSession?
    var componentPairReview: ComponentPairReview?
    private var pendingComponentPair: (ComponentPairReview, Architecture)?
    private let componentBuild: @Sendable (URL,URL,Architecture) throws -> ComponentReviewSession
    private(set) var isWritingInventory = false
    private var inventoryWriteFailedDuringQuit = false
    private let inventoryBuild: @Sendable (URL) throws -> ComponentInventory
    private let inventoryWrite: @Sendable (Data, URL) async throws -> Void
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
         }, inventoryBuild: @escaping @Sendable (URL) throws -> ComponentInventory = { try ComponentInventoryBuilder().build($0) },
         inventoryWrite: @escaping @Sendable (Data, URL) async throws -> Void = { data, url in
             try await Task.detached { try data.write(to: url, options: .atomic) }.value
         }, componentBuild: @escaping @Sendable (URL,URL,Architecture) throws -> ComponentReviewSession = { try ComponentReviewOperations.build($0,$1,$2) }, assessmentRunner: AssessmentRunner = AssessmentRunner(), projectStore:InspectionProjectStore?=nil,
         portableExport: @escaping @Sendable (InspectionProjectStore,UUID,Int,URL) async throws -> Void = { store,id,revision,url in
             try await store.exportPortableProject(id,to:url,expectedRevision:revision)
         }, portableReconstruct: @escaping @Sendable (PortableProjectAdmission,URL) async throws -> InspectionProjectStore = {
             try await PortableProjectReader.reconstruct($0,to:$1)
         }, portableSettledReconstruct: @escaping @Sendable (PortableSettledBatchAdmission,URL) async throws -> InspectionProjectStore = {
             try await PortableSettledBatchProject.reconstruct($0,to:$1)
         }, settledExportWrite:@escaping @Sendable (SettledProjectExportPreview,URL) async throws -> Void = {preview,target in
             try await Task.detached {try preview.write(to:target)}.value
         }) {
        self.settledExportWrite=settledExportWrite
        self.projectStore=projectStore ?? InspectionProjectStore(root:Self.defaultProjectRoot)
        self.portableExport=portableExport;self.portableReconstruct=portableReconstruct
        self.portableSettledReconstruct=portableSettledReconstruct
        self.assessmentRunner=assessmentRunner
        self.componentBuild = componentBuild
        self.inventoryBuild = inventoryBuild; self.inventoryWrite = inventoryWrite
        self.read = read; self.hasModal = hasModal
    }

    var blocksActions: Bool { decodeInventoryError != nil || decodeInventoryReview != nil || coverageReview != nil || policyReview != nil || intakeReview != nil || archiveReview != nil || inventoryReview != nil || componentReview != nil || assessmentReview != nil || projectReview != nil || componentPairReview != nil || isBusy || isPresentingPanel || isTerminating }

    func chooseReport(audit: AuditWorkspace, entitlements: EntitlementsWorkspace, navigation: AIRSNavigation) {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal() else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Open Report"
        panel.message = "Open an AIRS audit, entitlement comparison, inspection or review archive."
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "airsinspect") ?? .json, UTType(filenameExtension: "airsreview") ?? .json]
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
        if urls.contains(where: { $0.pathExtension.lowercased() == "app" }) {
            do {
                intakeReview = AppIntakeReview(request: try AppIntake.stage(urls),
                    auditRevision: audit.reportRevision, entitlementRevision: entitlements.model.reportRevision)
            } catch { errorMessage = "Choose one or two distinct local apps. Mixed app/report selections are unsupported." }
            return nil
        }
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else {
            errorMessage = "Open exactly one local file or app at a time."
            return nil
        }
        // Preserve the existing explicit binary/app route; JSON never falls through to analysis.
        guard ["json", "airsinspect", "airsreview"].contains(url.pathExtension.lowercased()) else {
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
                case .assessments, .componentReview:
                    throw InspectionArchiveError.invalid
                case .inventory(let inventory, let bytes):
                    inventoryReview = ComponentInventoryReview(inventory: inventory,
                        archiveBytes: try ComponentInventoryDocumentCodec.archive(payload: bytes), sourceURL: url, imported: true)
                case .archive(let archive, let bytes):
                    archiveReview = ArchiveReview(archive: archive, bytes: bytes, sourceURL: url,
                        auditRevision: auditRevision, entitlementRevision: entitlementRevision)
                case .audit(let report, let bytes):
                    audit.openValidatedReport(report, data: bytes, from: url)
                    navigation.showsEntitlements = false
                case .inspection(let document, let bytes):
                    entitlements.reviewValidatedInspection(document, data: bytes, from: url)
                    navigation.showsEntitlements = true
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

    func cancelArchiveReview() { activeTask?.cancel(); archiveReview = nil }

    @discardableResult
    func openArchiveAttachment(_ id: UUID, audit: AuditWorkspace,
                               entitlements: EntitlementsWorkspace, navigation: AIRSNavigation) -> Task<Void, Never>? {
        guard let review = archiveReview, !isBusy, !isTerminating,
              !audit.blocksFileOpen, !entitlements.isBusy,
              audit.reportRevision == review.auditRevision,
              entitlements.model.reportRevision == review.entitlementRevision else {
            status = "Workspace changed or busy; open the archive again when ready."; return nil
        }
        isBusy = true
        status = "Opening archive evidence…"
        let task = Task {
            defer { isBusy = false; activeTask = nil }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try AIRSOpenedReport.attachment(review.archive, id: id)
                }.value
                try Task.checkCancellation()
                guard !isTerminating, archiveReview?.id == review.id,
                      !audit.blocksFileOpen, !entitlements.isBusy,
                      audit.reportRevision == review.auditRevision,
                      entitlements.model.reportRevision == review.entitlementRevision else {
                    archiveReview = nil
                    status = "Workspace changed; archive evidence was not opened."; return
                }
                switch report {
                case .audit(let value, let bytes):
                    archiveReview = nil
                    audit.openValidatedReport(value, data: bytes, from: review.sourceURL)
                    navigation.showsEntitlements = false
                case .inspection(let value, let bytes):
                    archiveReview = nil
                    entitlements.reviewValidatedInspection(value, data: bytes, from: review.sourceURL)
                    navigation.showsEntitlements = true
                case .entitlements(let value):
                    archiveReview = nil
                    entitlements.reviewValidatedReport(value, from: review.sourceURL)
                    navigation.showsEntitlements = true
                case .assessments(let value):
                    archiveReview = nil
                    assessmentReview = .init(document:value,archiveBytes:review.bytes,sourceURLs:[review.sourceURL])
                case .componentReview(let value):
                    let session = try ComponentReviewSession(review:value,archiveBytes:review.bytes,sourceURLs:[review.sourceURL],live:nil)
                    archiveReview = nil; componentReview = session
                case .inventory(let value, _):
                    archiveReview = nil
                    inventoryReview = ComponentInventoryReview(inventory: value, archiveBytes: review.bytes,
                        sourceURL: review.sourceURL, imported: true)
                case .archive: throw InspectionArchiveError.invalid
                }
                status = ""
            } catch {
                status = Task.isCancelled || isTerminating ? "Archive opening cancelled. Existing sessions are unchanged." : error.localizedDescription
            }
        }
        activeTask = task
        return task
    }

    func swapIntake() {
        guard var review = intakeReview, case .compare(let previous, let current) = review.request else { return }
        review.request = .compare(previous: current, current: previous)
        intakeReview = review
    }
    func confirmIntake(unwind: Bool = false, audit: AuditWorkspace,
                       entitlements: EntitlementsWorkspace, navigation: AIRSNavigation) {
        guard let review = intakeReview, !isTerminating, !isBusy, !audit.blocksFileOpen,
              !entitlements.isBusy, audit.reportRevision == review.auditRevision,
              entitlements.model.reportRevision == review.entitlementRevision else {
            intakeReview = nil; status = "Workspace changed; select the apps again."; return
        }
        intakeReview = nil
        switch review.request {
        case .chooseTask(let url), .inspect(let url):
            if unwind { navigation.performAudit { audit.analyze(url) } }
            else { navigation.showsEntitlements = true; entitlements.inspectSingle(url) }
        case .compare(let previous, let current):
            navigation.showsEntitlements = true
            entitlements.inspectPair(previous: previous, current: current)
        }
    }

    var canCancel: Bool { isBusy && !isWritingInventory }
    func cancel() { if !isWritingInventory { activeTask?.cancel() } }
    @discardableResult
    func finishBeforeQuit() async -> Bool {
        isTerminating = true
        intakeReview = nil; archiveReview = nil
        if !isWritingInventory { activeTask?.cancel() }
        await activeTask?.value
        if inventoryWriteFailedDuringQuit { return false }
        portableProjectPreview=nil;settledProjectExportPreview=nil;settledExportGeneration=UUID();importedProjectHistory=nil
        inventoryReview = nil; decodeInventoryError=nil; decodeInventoryReview=nil; coverageReview=nil; policyReview=nil; projectReview=nil; assessmentReview = nil; componentReview = nil; componentPairReview = nil; pendingComponentPair = nil
        return true
    }
    func resumeAfterCancelledQuit() { isTerminating = false; inventoryWriteFailedDuringQuit = false }

    func chooseInventory(audit: AuditWorkspace, entitlements: EntitlementsWorkspace) {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal() else { return }
        isPresentingPanel = true
        let panel = NSOpenPanel()
        panel.title = "Inventory App Components"
        panel.message = "Read component headers and declared labels in bounded code locations. The app will not be executed."
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        let result = panel.runModal(); isPresentingPanel = false
        if result == .OK, let url = panel.url { inventory(url, audit: audit, entitlements: entitlements) }
    }

    @discardableResult
    func inventory(_ url: URL, audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> Task<Void, Never>? {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal(), url.isFileURL,
              url.pathExtension.lowercased() == "app" else { return nil }
        let auditRevision = audit.reportRevision, entitlementRevision = entitlements.model.reportRevision
        let build = inventoryBuild
        isBusy = true; status = "Reading component declarations…"
        let task = Task {
            defer { isBusy = false; activeTask = nil }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let inventory = try build(url)
                    return (inventory, try ComponentInventoryDocumentCodec.archive(inventory))
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard !isTerminating, !audit.blocksFileOpen, !entitlements.isBusy,
                      audit.reportRevision == auditRevision, entitlements.model.reportRevision == entitlementRevision else {
                    status = "Workspace changed; component inventory was not opened."; return
                }
                inventoryReview = ComponentInventoryReview(inventory: result.0, archiveBytes: result.1, sourceURL: url, imported: false)
                status = "Inventory ready. Architecture and minimum OS are declarations, not compatibility tests."
            } catch {
                if Task.isCancelled || isTerminating || error is CancellationError { status = "Component inventory cancelled; sessions are unchanged." }
                else { errorMessage = error.localizedDescription; status = "Component inventory failed; sessions are unchanged." }
            }
        }
        activeTask = task
        return task
    }

    func closeInventory() { guard !isBusy else { return }; inventoryReview = nil; status = "" }
    func chooseInventoryExport(audit: AuditWorkspace, entitlements: EntitlementsWorkspace) {
        guard policyReview?.result != nil || inventoryReview != nil || componentReview != nil || assessmentReview != nil, !isBusy, !isTerminating else { return }
        isPresentingPanel = true
        let panel = NSSavePanel(); panel.title = policyReview != nil ? "Export Policy Result JSON" : "Export Complete Review Archive"
        panel.nameFieldStringValue = policyReview != nil ? "policy-result.json" : assessmentReview != nil ? "app-assessments.airsreview" : "component-inventory.airsreview"
        panel.allowedContentTypes = policyReview != nil ? [.json] : [UTType(filenameExtension: "airsreview") ?? .json]
        let result = panel.runModal(); isPresentingPanel = false
        if result == .OK, let url = panel.url { exportInventory(to: url, audit: audit, entitlements: entitlements) }
    }
    @discardableResult
    func exportInventory(to url: URL, audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> Task<Void, Never>? {
        guard !isBusy, !isTerminating else { return nil }
        let bytes: Data, inputs: [URL]
        if let review=policyReview,let result=review.result {
            do {bytes=try result.data();inputs=review.prepared.inputURLs} catch {status=error.localizedDescription;return nil}
        }
        else if let review = assessmentReview { bytes = review.archiveBytes; inputs = review.sourceURLs }
        else if let review = componentReview { bytes = review.archiveBytes; inputs = review.sourceURLs }
        else if let review = inventoryReview { bytes = review.archiveBytes; inputs = [review.sourceURL] }
        else { return nil }
        do {
            try ReportDestination.validate(url, excluding: entitlements.protectedInputs + inputs)
            try audit.validateExportDestination(url, protectedInputs: inputs)
        } catch { status = error.localizedDescription; return nil }
        let write = inventoryWrite
        isBusy = true; isWritingInventory = true; inventoryWriteFailedDuringQuit = false
        status = policyReview != nil ? "Exporting policy result…" : "Exporting complete archive…"
        let task = Task {
            defer { isBusy = false; isWritingInventory = false; activeTask = nil }
            do {
                try await write(bytes, url)
                status = policyReview != nil ? "Policy JSON exported." : "Complete archive exported; display filters did not change its evidence."
            } catch {
                if isTerminating { inventoryWriteFailedDuringQuit = true }
                status = (policyReview != nil ? "Policy export failed; result is retained. " : "Archive export failed; inventory is retained. ") + error.localizedDescription
            }
        }
        activeTask = task
        return task
    }
    func chooseComponentComparison(audit: AuditWorkspace, entitlements: EntitlementsWorkspace) {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy, !hasModal() else { return }
        isPresentingPanel = true; defer { isPresentingPanel = false }
        func choose(_ title: String) -> URL? {
            let panel = NSOpenPanel(); panel.title = title; panel.allowedContentTypes = [.applicationBundle]
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let previous = choose("Choose Previous App"), let current = choose("Choose Current App") else { return }
        do {
            _ = try AppIntake.stage([previous,current])
            componentPairReview = .init(previous:previous,current:current,auditRevision:audit.reportRevision,entitlementRevision:entitlements.model.reportRevision)
        } catch { errorMessage = error.localizedDescription }
    }
    func swapComponentPair() {
        guard var pair = componentPairReview else { return }; swap(&pair.previous,&pair.current); componentPairReview = pair
    }
    func confirmComponentPair(_ architecture: Architecture, audit: AuditWorkspace, entitlements: EntitlementsWorkspace) {
        guard let pair = componentPairReview else { return }
        componentPairReview = nil
        guard pair.auditRevision == audit.reportRevision, pair.entitlementRevision == entitlements.model.reportRevision else { status = "Workspace changed; select the pair again."; return }
        pendingComponentPair = (pair, architecture)
    }
    @discardableResult
    func componentPairDismissed(audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> Task<Void,Never>? {
        guard let (pair, architecture) = pendingComponentPair else { return nil }
        pendingComponentPair = nil
        guard pair.auditRevision == audit.reportRevision, pair.entitlementRevision == entitlements.model.reportRevision else {
            status = "Workspace changed; select the pair again."; return nil
        }
        return compareComponents(previous:pair.previous,current:pair.current,architecture:architecture,audit:audit,entitlements:entitlements)
    }
    @discardableResult
    func compareComponents(previous: URL, current: URL, architecture: Architecture,
                           audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> Task<Void,Never>? {
        guard !blocksActions, !audit.blocksFileOpen, !entitlements.isBusy else { return nil }
        let build = componentBuild, auditRevision = audit.reportRevision, entitlementRevision = entitlements.model.reportRevision
        isBusy = true; status = "Building scoped component review…"
        let task = Task {
            defer { isBusy = false; activeTask = nil }
            do {
                let worker = Task.detached(priority:.userInitiated) {
                    let a = previous.startAccessingSecurityScopedResource(), b = current.startAccessingSecurityScopedResource()
                    defer { if a { previous.stopAccessingSecurityScopedResource() }; if b { current.stopAccessingSecurityScopedResource() } }
                    return try build(previous,current,architecture)
                }
                let session = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating, !audit.blocksFileOpen, !entitlements.isBusy,
                      audit.reportRevision == auditRevision, entitlements.model.reportRevision == entitlementRevision else { status = "Workspace changed; component review was not opened."; return }
                componentReview = session; status = "Review ready; entitlement reads require explicit requests."
            } catch {
                if Task.isCancelled || isTerminating || error is CancellationError { status = "Component review cancelled; sessions unchanged." }
                else { errorMessage = error.localizedDescription; status = "Component review failed; sessions unchanged." }
            }
        }
        activeTask = task; return task
    }
    func closeComponentReview() { guard !isBusy else { return }; componentReview = nil; status = "" }
    @discardableResult
    func readComponentEntitlements(_ id: UUID, audit: AuditWorkspace, entitlements: EntitlementsWorkspace) -> Task<Void,Never>? {
        guard let session = componentReview, session.live != nil, !isBusy, !isTerminating else { return nil }
        let auditRevision = audit.reportRevision, entitlementRevision = entitlements.model.reportRevision
        isBusy = true; status = "Reading explicitly requested code-unit slice…"
        let task = Task {
            defer { isBusy = false; activeTask = nil }
            do {
                let worker = Task.detached { try await ComponentReviewOperations.read(session,matchID:id) }
                let updated = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating, componentReview?.id == session.id,
                      audit.reportRevision == auditRevision, entitlements.model.reportRevision == entitlementRevision else { status = "Workspace changed; entitlement result discarded."; return }
                componentReview = updated; status = "Requested slice settled; unavailable results remain explicit."
            } catch { status = Task.isCancelled ? "Read cancelled; review retained." : error.localizedDescription }
        }
        activeTask = task; return task
    }

    func chooseDecodeInventory(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy,!hasModal() else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Open Saved Decoder Inventory";panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        let outcome=panel.runModal();isPresentingPanel=false
        if outcome == .OK,let url=panel.url {_=openDecodeInventory(url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func openDecodeInventory(_ url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace)->Task<Void,Never>? {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        isBusy=true;status="Reading saved decoder inventory; no image analysis…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let inventory=try await Task.detached {try DecodeInventory.decode(ReportFiles.readBounded(url))}.value
                try Task.checkCancellation();guard !isTerminating else {return}
                decodeInventoryReview=DecodeInventorySession(inventory:inventory,sourceURL:url)
                status="Saved decode observations loaded; no unwind verdict is implied."
            } catch {
                guard !Task.isCancelled,!isTerminating else {return}
                decodeInventoryError=error.localizedDescription
                status="Decoder inventory unavailable: "+error.localizedDescription
            }
        }
        activeTask=task;return task
    }
    func chooseDecodeAudit(_ rowID:String,audit:AuditWorkspace,entitlements:EntitlementsWorkspace,navigation:AIRSNavigation) {
        guard decodeInventoryReview != nil,!isBusy,!isTerminating,!audit.blocksFileOpen,!entitlements.isBusy else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Choose Saved Audit for Inventory Function";panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        let outcome=panel.runModal();isPresentingPanel=false
        if outcome == .OK,let url=panel.url {_=openDecodeAudit(rowID,source:url,audit:audit,entitlements:entitlements,navigation:navigation)}
    }
    @discardableResult
    func openDecodeAudit(_ rowID:String,source:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace,navigation:AIRSNavigation)->Task<Void,Never>? {
        guard let session=decodeInventoryReview,!isBusy,!isTerminating,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        let revision=audit.reportRevision,entitlementRevision=entitlements.model.reportRevision
        isBusy=true;status="Matching saved audit image and function; no image analysis…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let value=try await Task.detached {
                    let bytes=try ReportFiles.readBounded(source)
                    let resolved=try session.inventory.resolveFunction(rowID,sourceBytes:bytes)
                    return (bytes,resolved.0,resolved.1.id)
                }.value
                try Task.checkCancellation()
                guard !isTerminating,decodeInventoryReview?.id == session.id,audit.reportRevision == revision,
                      entitlements.model.reportRevision == entitlementRevision,!audit.blocksFileOpen,!entitlements.isBusy else {
                    status="Workspace changed; saved audit was not opened.";return
                }
                audit.openValidatedReport(value.1,data:value.0,from:source)
                audit.selection = .finding(value.2);audit.revealSelectedFinding()
                navigation.showsEntitlements=false;decodeInventoryReview=nil
                status="Matching saved audit opened; its observations and limits remain independent of the decoder inventory."
            } catch {
                guard !Task.isCancelled,!isTerminating else {return}
                status="Saved audit unavailable; inventory and workspace preserved. "+error.localizedDescription
            }
        }
        activeTask=task;return task
    }

    func dismissDecodeInventoryError() {decodeInventoryError=nil}
    func closeDecodeInventory() {guard !isBusy else {return};decodeInventoryReview=nil;status=""}

    func chooseCoverage(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy,!hasModal() else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Open Saved Coverage Inventory";panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        let outcome=panel.runModal();isPresentingPanel=false
        if outcome == .OK,let url=panel.url {_=openCoverage(url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func openCoverage(_ url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace)->Task<Void,Never>? {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        isBusy=true;status="Reading saved coverage inventory; no image audit…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let inventory=try await Task.detached {try CoverageInventory.decode(ReportFiles.readBounded(url))}.value
                try Task.checkCancellation();guard !isTerminating else {return}
                coverageReview=CoverageReviewSession(inventory:inventory,sourceURL:url)
                status="Saved counts loaded. Aggregation status is separate from analysis completeness."
            } catch {status="Coverage inventory unavailable: "+error.localizedDescription}
        }
        activeTask=task;return task
    }
    func chooseCoverageObservation(_ example:CoverageInventory.Example,reason:String,audit:AuditWorkspace,entitlements:EntitlementsWorkspace,navigation:AIRSNavigation) {
        guard coverageReview != nil,!isBusy,!isTerminating,!audit.blocksFileOpen,!entitlements.isBusy else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Choose Saved Audit Report for Referenced Observation";panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        let outcome=panel.runModal();isPresentingPanel=false
        if outcome == .OK,let url=panel.url {_=openCoverageObservation(example,reason:reason,source:url,audit:audit,entitlements:entitlements,navigation:navigation)}
    }
    @discardableResult
    func openCoverageObservation(_ example:CoverageInventory.Example,reason:String,source:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace,navigation:AIRSNavigation)->Task<Void,Never>? {
        guard let session=coverageReview,!isBusy,!isTerminating,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        let revision=audit.reportRevision,entitlementRevision=entitlements.model.reportRevision
        isBusy=true;status="Resolving selected saved observation…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let value=try await Task.detached {
                    let bytes=try ReportFiles.readBounded(source)
                    let resolved=try session.inventory.resolve(example,reason:reason,sourceBytes:bytes)
                    return (bytes,resolved.0,resolved.1.id)
                }.value
                try Task.checkCancellation()
                guard !isTerminating,coverageReview?.id == session.id,audit.reportRevision == revision,entitlements.model.reportRevision == entitlementRevision,!audit.blocksFileOpen,!entitlements.isBusy else {
                    status="Workspace changed; referenced observation was not opened.";return
                }
                audit.openValidatedReport(value.1,data:value.0,from:source);audit.selection = .finding(value.2);audit.revealSelectedFinding()
                navigation.showsEntitlements=false;coverageReview=nil;status="Selected saved observation matches the reference; source issues and limits remain visible."
            } catch {status="Source observation unavailable; sessions preserved. "+error.localizedDescription}
        }
        activeTask=task;return task
    }
    func closeCoverage() {guard !isBusy else {return};coverageReview=nil;status=""}

    func choosePolicyReview(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy,!hasModal() else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Open Owned-build Policy Request (Saved Evidence Only)";panel.allowedContentTypes=[.json];panel.allowsMultipleSelection=false
        let outcome=panel.runModal();isPresentingPanel=false
        if outcome == .OK,let url=panel.url {_=openPolicyReview(url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func openPolicyReview(_ url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace)->Task<Void,Never>? {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        isBusy=true;status="Reading saved policy request; no target checks…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let prepared=try await Task.detached {try ReviewPolicyCommand(arguments:["--request",url.path]).prepare()}.value
                try Task.checkCancellation()
                guard !isTerminating else {return}
                policyReview=PolicyReviewSession(prepared:prepared);status="Confirm the explicit request mode before evaluation."
            } catch {status="Policy request unavailable: "+error.localizedDescription}
        }
        activeTask=task;return task
    }
    func evaluatePolicyReview() {
        guard var session=policyReview,!isBusy,!isTerminating,session.result == nil else {return}
        session.result=session.prepared.evaluate();policyReview=session
        status="Recorded policy evaluation complete. Missing evidence never passes."
    }
    func closePolicyReview() {guard !isBusy else {return};policyReview=nil;status=""}

    func chooseAssessment(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy,!hasModal() else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel(); panel.title="Select App for Scoped Assessments"
        panel.message="Capture a bounded content identity; no signature or distribution check runs until explicitly requested. Links and special files are outside the first supported identity scope."
        panel.allowedContentTypes=[.applicationBundle]; panel.allowsMultipleSelection=false
        let accepted=panel.runModal() == .OK; let url=panel.url; isPresentingPanel=false
        if accepted,let url {_=buildAssessment(url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func buildAssessment(_ url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy else {return nil}
        let a=audit.reportRevision,b=entitlements.model.reportRevision
        isBusy=true; status="Capturing bounded assessment subject…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let worker=Task.detached {try AssessmentReviewSession.capture(url)}
                let session=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating,audit.reportRevision == a,entitlements.model.reportRevision == b else {return}
                assessmentReview=session;status="No assessments performed. Choose an explicit operation."
            } catch {status=Task.isCancelled ? "Capture cancelled." : error.localizedDescription;errorMessage=Task.isCancelled ? nil : error.localizedDescription}
        }
        activeTask=task;return task
    }
    @discardableResult
    func runAssessment(_ kind:AssessmentKind,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard let session=assessmentReview,let identity=session.identity,session.evaluationID != nil,
              !isBusy,!isTerminating,session.document.results.count < 64,
              !session.document.results.contains(where:{$0.kind == kind}) else {return nil}
        let a=audit.reportRevision,b=entitlements.model.reportRevision,runner=assessmentRunner
        isBusy=true;status="Assessment running. Cancellation retains ownership until the OS operation settles."
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            let result=await runner.run(kind,identity:identity,documentDigest:AssessmentDocument.digest(session.document.subjectDocument))
            guard !isTerminating,assessmentReview?.id == session.id,audit.reportRevision == a,entitlements.model.reportRevision == b else {return}
            do {assessmentReview=try session.adding(result);status="Assessment settled; result applies only to the recorded scope."}
            catch {status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func closeAssessment() {guard !isBusy else {return};assessmentReview=nil;status=""}

    static var defaultProjectRoot:URL {
        #if DEBUG
        if let root=ProcessInfo.processInfo.environment["AIRS_PROJECT_REVIEW_ROOT"],root.hasPrefix("/") {return URL(fileURLWithPath:root)}
        #endif
        let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("AIRS/InspectionProjects")
    }
    func configureProjectProtection(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        let protected=[projectStore.storageRoot]+projectImports
        audit.projectProtectedInputs=protected;entitlements.projectProtectedInputs=protected
        let generation=UUID();projectAssociationGeneration=generation;let store=projectStore
        Task {
            if let entries=try? await store.entries(),generation == projectAssociationGeneration {
                applyProjectAssociations(entries,audit:audit,entitlements:entitlements)
            }
        }
    }
    private func applyProjectAssociations(_ entries:[InspectionProjectEntry],audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        var a:[UUID:[UUID]]=[:],b:[UUID:[UUID]]=[:]
        for project in entries.compactMap(\.project) {
            for link in project.batchLinks {
                if link.family == .audit {a[link.historyID,default:[]].append(project.id)}
                else {b[link.historyID,default:[]].append(project.id)}
            }
        }
        audit.projectHistoryIDs=a;entitlements.projectHistoryIDs=b
    }
    func openProjects(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !blocksActions,!audit.blocksFileOpen,!entitlements.isBusy,!hasModal() else {return}
        configureProjectProtection(audit:audit,entitlements:entitlements)
        projectReview=ProjectReviewSession()
        let selected=selectedProjectID
        _=projectOperation("Loading projects…",writing:false,audit:audit,entitlements:entitlements) {_ in selected}
    }
    private func projectState(_ selected:UUID?,sessionID:UUID,store:InspectionProjectStore?=nil) async throws -> ProjectReviewSession {
        let projectStore=store ?? self.projectStore
        let entries=try await projectStore.entries()
        // A remembered ID is a selection hint, not authority to hide the list
        // when that manifest is unavailable. Reuse the parsed entry metadata.
        let project=entries.first(where:{$0.id == selected && $0.project != nil})?.project
            ?? entries.first(where:{$0.project != nil})?.project
        var issues:[UUID:String]=[:]
        if let project {
            for item in project.evidence {
                do {_=try await projectStore.evidence(item.id,in:project.id)} catch {issues[item.id]=error.localizedDescription}
            }
        }
        var unreferenced:[UUID]=[],issue:String?
        do {unreferenced=try await projectStore.unreferencedEvidence()} catch {issue="Retention references unavailable: "+error.localizedDescription}
        return .init(id:sessionID,entries:entries,project:project,evidenceIssues:issues,unreferenced:unreferenced,retentionIssue:issue)
    }
    @discardableResult
    func projectOperation(_ label:String,writing:Bool,audit:AuditWorkspace,entitlements:EntitlementsWorkspace,
                          operation:@escaping @Sendable (InspectionProjectStore)async throws->UUID?) -> Task<Void,Never>? {
        guard let session=projectReview,!hasPortableProjectPreview,!isBusy,!isTerminating else {return nil}
        let store=projectStore;isBusy=true;isWritingInventory=writing;inventoryWriteFailedDuringQuit=false;status=label
        let task=Task {
            defer {isBusy=false;isWritingInventory=false;activeTask=nil}
            do {
                let selected=try await operation(store)
                if !writing {try Task.checkCancellation()}
                let state=try await projectState(selected,sessionID:session.id)
                guard !isTerminating,projectReview?.id == session.id else {return}
                selectedProjectID=state.project?.id;projectReview=state
                projectAssociationGeneration=UUID();applyProjectAssociations(state.entries,audit:audit,entitlements:entitlements)
                status="Project metadata settled; original observations were not rewritten."
            } catch {
                if isTerminating && writing {inventoryWriteFailedDuringQuit=true}
                status=error.localizedDescription
            }
        }
        activeTask=task;return task
    }
    func selectProject(_ id:UUID,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        _=projectOperation("Loading project…",writing:false,audit:audit,entitlements:entitlements) {_ in id}
    }
    func createProject(_ name:String,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        _=projectOperation("Creating project…",writing:true,audit:audit,entitlements:entitlements) {try await $0.create(name:name).id}
    }
    func renameProject(_ name:String,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard var project=projectReview?.project else {return};let revision=project.revision;project.name=name;project.revision += 1
        let proposed=project
        _=projectOperation("Saving project name…",writing:true,audit:audit,entitlements:entitlements) {store in
            try await store.save(proposed,expectedRevision:revision);return proposed.id
        }
    }
    func pinProjectBaseline(_ id:UUID?,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard let project=projectReview?.project else {return}
        _=projectOperation("Saving baseline selection…",writing:true,audit:audit,entitlements:entitlements) {try await $0.pinBaseline(id,in:project.id,expectedRevision:project.revision).id}
    }
    func annotateProject(_ text:String,acknowledged:Bool,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard let project=projectReview?.project else {return}
        _=projectOperation("Saving separate review note…",writing:true,audit:audit,entitlements:entitlements) {try await $0.addAnnotation(text,acknowledged:acknowledged,to:project.id,expectedRevision:project.revision).id}
    }
    func linkProjectBatch(_ link:ProjectBatchLink,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard let project=projectReview?.project else {return}
        _=projectOperation("Linking batch metadata…",writing:true,audit:audit,entitlements:entitlements) {try await $0.linkBatch(link,to:project.id,expectedRevision:project.revision).id}
    }
    func removeProjectEvidence(_ id:UUID,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard let project=projectReview?.project else {return}
        _=projectOperation("Removing membership only…",writing:true,audit:audit,entitlements:entitlements) {store in
            try await store.removeEvidence(id,from:project.id,expectedRevision:project.revision);return project.id
        }
    }
    func removeUnreferencedProjectEvidence(_ id:UUID,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        let selected=projectReview?.project?.id
        _=projectOperation("Moving unreferenced retained copy to Trash…",writing:true,audit:audit,entitlements:entitlements) {store in
            try await store.removeRetainedEvidence(id);return selected
        }
    }
    func removeProject(_ id:UUID,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        let selected=projectReview?.project?.id
        _=projectOperation("Moving project metadata to Trash…",writing:true,audit:audit,entitlements:entitlements) {store in
            try await store.removeProject(id);return selected == id ? nil : selected
        }
    }
    func chooseProjectEvidence(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !hasPortableProjectPreview,projectReview?.project != nil,!isBusy else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Import Immutable Project Evidence";panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[.json,UTType(filenameExtension:"airsreview") ?? .data,UTType(filenameExtension:"airsinspect") ?? .data]
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        if accepted,let url {_=importProjectEvidence(url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func importProjectEvidence(_ url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard !hasPortableProjectPreview,let project=projectReview?.project,!isBusy else {return nil}
        if !projectImports.contains(url) {projectImports.append(url)}
        configureProjectProtection(audit:audit,entitlements:entitlements)
        return projectOperation("Retaining original evidence…",writing:true,audit:audit,entitlements:entitlements) {store in
            let bytes=try await Task.detached {
                let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
                return try Self.projectArchive(ReportFiles.readBounded(url,limit:InspectionArchive.maximumBytes))
            }.value
            return try await store.addEvidence(bytes,to:project.id,expectedRevision:project.revision).id
        }
    }
    nonisolated static func projectArchive(_ data:Data) throws -> Data {
        let kind:String
        switch try AIRSOpenedReport.parse(data) {
        case .archive: return data
        case .audit: kind="airs.audit"
        case .inspection: kind=InspectionDocument.kind
        case .entitlements: kind="EntitlementDiff"
        case .inventory: kind=ComponentInventoryDocumentCodec.kind
        case .assessments,.componentReview: throw InspectionArchiveError.invalid
        }
        let digest=AssessmentDocument.digest(data),prefix=String(digest.prefix(32))
        let parts=[String(prefix.prefix(8)),String(prefix.dropFirst(8).prefix(4)),String(prefix.dropFirst(12).prefix(4)),String(prefix.dropFirst(16).prefix(4)),String(prefix.dropFirst(20))]
        let name=parts.joined(separator:"-")
        guard let id=UUID(uuidString:String(name)) else {throw InspectionArchiveError.invalid}
        // Stable wrapper identity keeps repeated raw-document imports idempotent.
        return try InspectionArchive(attachments:[.init(id:id,kind:kind,schemaVersion:1,mediaType:"application/json",sha256:digest,byteCount:data.count,bytes:data)]).encode()
    }
    func reviewProjectEvidence(_ id:UUID,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard !hasPortableProjectPreview,let project=projectReview?.project,!isBusy,!isTerminating else {return}
        let a=audit.reportRevision,b=entitlements.model.reportRevision,store=projectStore,session=projectReview?.id
        isBusy=true;status="Opening retained historical evidence…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let bytes=try await store.evidence(id,in:project.id)
                let archive=try InspectionArchive.decode(bytes)
                try Task.checkCancellation()
                guard !isTerminating,projectReview?.id == session,audit.reportRevision == a,entitlements.model.reportRevision == b else {return}
                projectReview=nil
                archiveReview = .init(archive:archive,bytes:bytes,sourceURL:store.storageRoot.appendingPathComponent("Evidence/\(id.uuidString)/report.json"),auditRevision:a,entitlementRevision:b)
            } catch {status=error.localizedDescription}
        }
        activeTask=task
    }
    @discardableResult
    func exportProjectEvidence(_ id:UUID?,to destination:URL?=nil,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard !hasPortableProjectPreview,let session=projectReview,!isBusy,!isTerminating else {return nil}
        let store=projectStore,write=inventoryWrite,inputs=[store.storageRoot]+projectImports
        isBusy=true;isWritingInventory=true;inventoryWriteFailedDuringQuit=false;status="Exporting project evidence…"
        let task=Task {
            defer {isBusy=false;isWritingInventory=false;activeTask=nil}
            do {
                let bytes:Data
                if let id {
                    if let project=session.project,project.evidence.contains(where:{$0.id == id}) {bytes=try await store.evidence(id,in:project.id)}
                    else {bytes=try await store.evidence(id)}
                } else {guard let project=session.project else {throw InspectionArchiveError.invalid};bytes=try project.data()}
                var output=destination
                if output == nil {
                    let panel=NSSavePanel();panel.title=id == nil ? "Export Project Metadata (References and Notes Only)" : "Export Original Evidence Archive"
                    panel.nameFieldStringValue=id == nil ? "project-metadata.json" : "project-evidence.airsreview"
                    if panel.runModal() == .OK {output=panel.url}
                }
                guard let output else {status="Export cancelled.";return}
                try ReportDestination.validate(output,excluding:entitlements.protectedInputs+inputs)
                try audit.validateExportDestination(output,protectedInputs:inputs)
                try await write(bytes,output);status=id == nil ? "Project metadata exported; evidence bytes are separate." : "Original retained archive exported."
            } catch {if isTerminating {inventoryWriteFailedDuringQuit=true};status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func previewPortableProjectExport() {
        guard !hasPortableProjectPreview,!isBusy,!isTerminating,let session=projectReview,let project=session.project else {return}
        portablePreviewGeneration=UUID()
        portableProjectPreview = .init(sessionID:session.id,purpose:.export,project:project,admission:nil)
        status="Review the original evidence and notes included in this package."
    }
    func cancelPortableProjectPreview() {
        guard !isWritingInventory else {return}
        if isBusy {activeTask?.cancel()}
        portablePreviewGeneration=UUID();portableProjectPreview=nil
        settledExportGeneration=UUID();settledProjectExportPreview=nil
    }
    func choosePortableProjectPackage() {
        guard !hasPortableProjectPreview,projectReview != nil,!isBusy,!isTerminating else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Preview Portable Project";panel.prompt="Preview"
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.treatsFilePackagesAsDirectories=true
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        if accepted,let url {_=previewPortableProjectPackage(url)}
    }
    @discardableResult
    func previewPortableProjectPackage(_ url:URL) -> Task<Void,Never>? {
        guard !hasPortableProjectPreview,let session=projectReview,!isBusy,!isTerminating else {return nil}
        let generation=UUID();portablePreviewGeneration=generation;portableProjectPreview=nil
        isBusy=true;status="Validating portable package for preview…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let worker=Task.detached(priority:.userInitiated) {
                    let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
                    return try PortableProjectReader.prepare(at:url)
                }
                let admission=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating,projectReview?.id == session.id,portablePreviewGeneration == generation else {return}
                portableProjectPreview = .init(sessionID:session.id,purpose:.reconstruct,project:admission.project,admission:admission)
                status="Package validated. Reconstruction will create a separate new store."
            } catch {status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func chooseSettledProjectPackage() {
        guard !hasPortableProjectPreview,projectReview != nil,!isBusy,!isTerminating else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Preview Project with Historical Batch Outcomes";panel.prompt="Preview"
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.treatsFilePackagesAsDirectories=true
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        if accepted,let url {_=previewSettledProjectPackage(url)}
    }
    @discardableResult
    func previewSettledProjectPackage(_ url:URL) -> Task<Void,Never>? {
        guard !hasPortableProjectPreview,let session=projectReview,!isBusy,!isTerminating else {return nil}
        let generation=UUID();portablePreviewGeneration=generation
        isBusy=true;status="Validating companion package and historical outcomes…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let worker=Task.detached(priority:.userInitiated) {
                    let access=url.startAccessingSecurityScopedResource()
                    defer {if access {url.stopAccessingSecurityScopedResource()}}
                    return try PortableSettledBatchProject.prepare(at:url)
                }
                let admission=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating,projectReview?.id == session.id,portablePreviewGeneration == generation else {return}
                portableProjectPreview = .init(sessionID:session.id,purpose:.reconstruct,project:admission.project.project,
                    admission:admission.project,settledAdmission:admission,sourceURL:url)
                status="Companion validated. Historical outcomes are read-only; reconstruction creates a separate new store."
            } catch {status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func choosePortableProjectDestination(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard let preview=portableProjectPreview,!isBusy,!isTerminating else {return}
        isPresentingPanel=true
        let panel=NSSavePanel();panel.canCreateDirectories=true
        panel.title=preview.purpose == .export ? "Export Portable Project" : "Reconstruct into New Project Store"
        panel.nameFieldStringValue=preview.purpose == .export ? "Project.airsproject" : "Reconstructed AIRS Store"
        panel.message="Choose a new directory name. Existing destinations will be preserved."
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        guard accepted,let url else {return}
        if preview.purpose == .export {_=exportPortableProject(to:url,confirmed:true,audit:audit,entitlements:entitlements)}
        else {_=reconstructPortableProject(to:url,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func exportPortableProject(to url:URL,confirmed:Bool,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard confirmed,let preview=portableProjectPreview,preview.purpose == .export,
              preview.sessionID == projectReview?.id,!isBusy,!isTerminating else {return nil}
        let store=projectStore,export=portableExport
        isBusy=true;isWritingInventory=true;inventoryWriteFailedDuringQuit=false;status="Exporting portable project…"
        let task=Task {
            defer {isBusy=false;isWritingInventory=false;activeTask=nil}
            do {
                try ReportDestination.validate(url,excluding:entitlements.protectedInputs+[store.storageRoot]+projectImports)
                try audit.validateExportDestination(url,protectedInputs:[store.storageRoot]+projectImports)
                try await export(store,preview.project.id,preview.project.revision,url)
                status="Portable project exported. Original observations and source store preserved."
                guard !isTerminating,portableProjectPreview?.id == preview.id else {return}
                portableProjectPreview=nil
            } catch {if isTerminating {inventoryWriteFailedDuringQuit=true};status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    @discardableResult
    func reconstructPortableProject(to url:URL,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard let preview=portableProjectPreview,preview.purpose == .reconstruct,let admission=preview.admission,
              preview.sessionID == projectReview?.id,!isBusy,!isTerminating else {return nil}
        let reconstruct=portableReconstruct,reconstructSettled=portableSettledReconstruct
        let sourceStore=projectStore,selected=projectReview?.project?.id,sourceHistory=importedProjectHistory
        let sourceURL=preview.sourceURL ?? admission.packageURL
        isBusy=true;isWritingInventory=true;inventoryWriteFailedDuringQuit=false;status="Reconstructing a fresh project store…"
        let task=Task {
            defer {isBusy=false;isWritingInventory=false;activeTask=nil}
            do {
                try ReportDestination.validate(url,excluding:entitlements.protectedInputs+[sourceStore.storageRoot,sourceURL]+projectImports)
                try audit.validateExportDestination(url,protectedInputs:[sourceStore.storageRoot,sourceURL]+projectImports)
                let worker=Task.detached(priority:.userInitiated) {
                    let access=sourceURL.startAccessingSecurityScopedResource()
                    defer {if access {sourceURL.stopAccessingSecurityScopedResource()}}
                    if let settled=preview.settledAdmission {return try await reconstructSettled(settled,url)}
                    return try await reconstruct(admission,url)
                }
                let store=try await worker.value
                let state=try await projectState(admission.project.id,sessionID:preview.sessionID,store:store)
                status="New store reconstructed at \(url.path). Original store preserved."
                guard !isTerminating,projectReview?.id == preview.sessionID,portableProjectPreview?.id == preview.id else {return}
                if originalProjectContext == nil {originalProjectContext=(sourceStore,selected,sourceHistory)}
                projectImports += [sourceStore.storageRoot,sourceURL]
                importedProjectHistory=preview.settledAdmission.map {
                    ImportedProjectHistorySnapshot(projectID:admission.project.id,revision:admission.project.revision,storeRoot:store.storageRoot,history:$0.history)
                }
                projectStore=store;selectedProjectID=state.project?.id;projectReview=state;portableProjectPreview=nil
                configureProjectProtection(audit:audit,entitlements:entitlements)
            } catch {if isTerminating {inventoryWriteFailedDuringQuit=true};status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    @discardableResult
    func returnToOriginalProjectStore(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard let context=originalProjectContext,let session=projectReview,!hasPortableProjectPreview,!isBusy,!isTerminating else {return nil}
        isBusy=true;status="Opening original project store…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let state=try await projectState(context.selected,sessionID:session.id,store:context.store)
                try Task.checkCancellation();guard !isTerminating,projectReview?.id == session.id else {return}
                projectImports.append(projectStore.storageRoot)
                projectStore=context.store;importedProjectHistory=context.history
                selectedProjectID=state.project?.id;projectReview=state;originalProjectContext=nil
                configureProjectProtection(audit:audit,entitlements:entitlements)
                status="Original project store reopened. Reconstructed store remains on disk."
            } catch {status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func chooseSettledProjectExport(_ purpose:SettledProjectExportPreview.Purpose,entitlements:EntitlementsWorkspace) {
        guard !hasPortableProjectPreview,projectReview?.project != nil,!isBusy,!isTerminating else {return}
        isPresentingPanel=true
        let panel=NSOpenPanel();panel.title="Choose Exact Package for Selected Project";panel.prompt="Preview"
        panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        panel.treatsFilePackagesAsDirectories=true
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        if accepted,let url {_=prepareSettledProjectExport(package:url,purpose:purpose,historyReader:{@Sendable project in try await entitlements.preparePortableBatchHistory(project)})}
    }
    @discardableResult
    func prepareSettledProjectExport(package url:URL,purpose:SettledProjectExportPreview.Purpose,
        historyReader:@escaping @Sendable (InspectionProject) async throws -> PortableSettledBatchEvidence) -> Task<Void,Never>? {
        guard !hasPortableProjectPreview,let session=projectReview,let selected=session.project,!isBusy,!isTerminating else {return nil}
        let generation=UUID();settledExportGeneration=generation
        let store=projectStore.storageRoot
        isBusy=true;status="Preparing original project and historical outcomes for consent…"
        let task=Task {
            defer {isBusy=false;activeTask=nil}
            do {
                let worker=Task.detached(priority:.userInitiated) {
                    let access=url.startAccessingSecurityScopedResource()
                    defer {if access {url.stopAccessingSecurityScopedResource()}}
                    return try await SettledProjectExportPreview.prepare(packageURL:url,store:store,selected:selected,sessionID:session.id,purpose:purpose,historyReader:historyReader)
                }
                let preview=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation()
                guard !isTerminating,settledExportGeneration == generation,preview.matches(session:projectReview,store:projectStore.storageRoot) else {return}
                settledProjectExportPreview=preview
                status="Review original evidence, notes and historical outcomes before choosing a new destination."
            } catch {status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func cancelSettledProjectExport() {
        guard !isWritingInventory else {return}
        if isBusy {activeTask?.cancel()}
        settledExportGeneration=UUID();settledProjectExportPreview=nil
    }
    func chooseSettledProjectExportDestination(audit:AuditWorkspace,entitlements:EntitlementsWorkspace) {
        guard settledProjectExportPreview != nil,!isBusy,!isTerminating else {return}
        isPresentingPanel=true
        let panel=NSSavePanel();panel.title="Export Historical Companion to New Directory"
        panel.nameFieldStringValue="Project with Recorded Outcomes";panel.canCreateDirectories=true
        panel.message="Choose an absent directory. Existing destinations are preserved."
        let accepted=panel.runModal() == .OK,url=panel.url;isPresentingPanel=false
        if accepted,let url {_=writeSettledProjectExport(to:url,confirmed:true,audit:audit,entitlements:entitlements)}
    }
    @discardableResult
    func writeSettledProjectExport(to target:URL,confirmed:Bool,audit:AuditWorkspace,entitlements:EntitlementsWorkspace) -> Task<Void,Never>? {
        guard confirmed,let preview=settledProjectExportPreview,preview.matches(session:projectReview,store:projectStore.storageRoot),!isBusy,!isTerminating else {return nil}
        let write=settledExportWrite
        isBusy=true;isWritingInventory=true;inventoryWriteFailedDuringQuit=false
        status="Writing original project and detached historical outcomes…"
        let task=Task {
            defer {isBusy=false;isWritingInventory=false;activeTask=nil}
            do {
                let protected=projectImports+[preview.sourceStore,preview.package.packageURL]
                try ReportDestination.validate(target,excluding:entitlements.protectedInputs+protected)
                try audit.validateExportDestination(target,protectedInputs:protected)
                let access=preview.package.packageURL.startAccessingSecurityScopedResource()
                defer {if access {preview.package.packageURL.stopAccessingSecurityScopedResource()}}
                try await write(preview,target)
                status="Historical companion exported. Original project store and live queues preserved."
                guard !isTerminating,settledProjectExportPreview?.id == preview.id else {return}
                settledProjectExportPreview=nil
            } catch {if isTerminating {inventoryWriteFailedDuringQuit=true};status=error.localizedDescription}
        }
        activeTask=task;return task
    }
    func closeProjects() {guard !isBusy else {return};cancelPortableProjectPreview();projectReview=nil;status=""}

}
