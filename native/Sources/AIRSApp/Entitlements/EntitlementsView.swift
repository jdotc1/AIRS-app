import SwiftUI
import LumenUI
import EntitlementDiffCore
import EntitlementDiffModel

/// AIRS-owned composition; reused donor views have no scene or command ownership.
struct EntitlementsView: View {
    @Bindable var workspace: EntitlementsWorkspace
    var navigationAllowed = true

    var body: some View {
        VStack(spacing: 0) {
            if workspace.showingInspectionLibrary {
                InspectionLibraryView(workspace: workspace)
            } else if workspace.showingBatchRecovery {
                EntitlementBatchRecoveryView(workspace: workspace)
            } else if workspace.showingBatchHistory {
                EntitlementBatchHistoryView(workspace: workspace)
            } else if workspace.showingBatch {
                EntitlementBatchView(workspace: workspace)
            } else if workspace.showingLibrary {
                EntitlementLibraryView(workspace: workspace)
            } else {
                EntitlementsHeader(workspace: workspace)
                Divider()
                if let report = workspace.model.report {
                    EntitlementsBrowser(workspace: workspace, navigationAllowed: navigationAllowed)
                    Text(report.notices.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                } else if let input = workspace.standaloneInspection {
                    StandaloneEntitlementsView(input: input,
                        disabled: workspace.isBusy || !navigationAllowed)
                        .id(input.id)
                } else {
                    EntitlementsEmptyView(workspace: workspace)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $workspace.inspectionReview) { context in
            InspectionReviewView(context: context, adopt: workspace.adoptInspection,
                cancel: { workspace.inspectionReview = nil }).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { workspace.captureSide != nil }, set: { if !$0 { workspace.captureSide = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Capture Baseline").font(.title2.bold())
                TextField("Baseline name", text: $workspace.captureName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { workspace.captureSide = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Keep Baseline") {
                        let side = workspace.captureSide
                        workspace.captureSide = nil
                        if let side { workspace.captureBaseline(side, label: workspace.captureName) }
                    }.disabled(workspace.captureName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 440)
        }
        .sheet(item: $workspace.batchManifestReview) { review in
            EntitlementBatchManifestReviewView(review: review,
                adopt: { workspace.adoptBatchManifest(review.id) },
                cancel: { workspace.cancelBatchManifest(review.id) })
                .interactiveDismissDisabled()
        }
        .sheet(item: $workspace.savedReport) { report in
            SavedBaselineView(report: report, adopt: workspace.adoptSavedBaseline,
                              openComparison: workspace.openSavedComparison, cancel: workspace.cancelReview)
                .interactiveDismissDisabled()
        }
        .sheet(item: $workspace.focusedValue) { selection in
            FocusedValueView(selection: selection, actions: workspace)
        }
        .sheet(item: $workspace.entitlementFind, onDismiss: workspace.finishFindPresentation) { session in
            FindEntitlementView(
                find: { workspace.findEntitlement($0, revealHidden: $1, sessionID: session.id) },
                cancel: { workspace.cancelFindEntitlement(sessionID: session.id) })
        }
        .alert("AIRS — Entitlements", isPresented: Binding(
            get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } }
        )) { Button("OK") { workspace.errorMessage = nil } }
        message: { Text(DisplayText.escaped(workspace.errorMessage ?? "")) }
    }
}

private struct EntitlementsHeader: View {
    @Bindable var workspace: EntitlementsWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.regular) {
            HStack(spacing: AppDesign.Space.regular) {
                Text(workspace.standaloneInspection == nil ? "Compare Entitlements" : "Inspect Entitlements")
                    .font(AppDesign.Layout.pageTitle)
                Spacer(minLength: AppDesign.Space.regular)
                Picker("Architecture", selection: Binding(
                    get: { workspace.model.architecture }, set: workspace.setArchitecture
                )) {
                    ForEach(Architecture.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 200).disabled(!workspace.canChangeArchitecture).help(workspace.architectureChangeReason)
            }
            Button("Inspection Baselines…") { workspace.openInspectionLibrary() }.disabled(workspace.isBusy)
            Text("Main executable and requested architecture only. Extraction is not signature validation, effective permissions, Gatekeeper evaluation or a trust verdict.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: AppDesign.Space.regular) {
                capturePane(.previous, state: workspace.model.previous)
                capturePane(.current, state: workspace.model.current)
            }
        }
        .padding(.horizontal, AppDesign.Space.section)
        .padding(.vertical, AppDesign.Space.regular)
    }
    private func capturePane(_ side: ComparisonSide, state: InputState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            pane(side, state: state)
            if let context = workspace.inspectionContexts[side] {
                Text("Captured \(context.document.capturedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Capture Baseline…") { workspace.requestCapture(side) }
                    Button("Export Inspection…") { workspace.chooseInspectionExport(side) }
                }.disabled(workspace.isBusy)
            } else if state.snapshot?.isSavedBaseline == true {
                Text("Capture metadata unavailable in this legacy report.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pane(_ side: ComparisonSide, state: InputState) -> some View {
        SourcePane(side: side, state: state, disabled: workspace.isBusy,
                   sourceURL: workspace.model.selectedSourceURL(for: side), reveal: { workspace.reveal(side) },
                   canReload: workspace.model.canReload(side), reload: { workspace.reload(side) },
                   choose: { workspace.choose(side) }, clear: { workspace.clear(side) },
                   drop: { workspace.drop($0, side: side) })
    }
}

struct EntitlementsBrowser: View {
    @Bindable var workspace: EntitlementsWorkspace
    var navigationAllowed = true
    var body: some View {
        @Bindable var model = workspace.model
        VStack(spacing: AppDesign.Space.small) {
            HStack(spacing: AppDesign.Space.medium) {
                TextField("Filter entitlement keys", text: Binding(
                    get: { model.browser.query },
                    set: { model.browser.query = String($0.unicodeScalars.prefix(256)) }
                )).textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 240)
                Picker("Show", selection: $model.browser.filter) {
                    ForEach(BrowserFilter.allCases, id: \.self) { filter in
                        Text("\(filter.label) (\(model.browser.count(filter)))").tag(filter)
                    }
                }.labelsHidden().frame(width: 185)
                Spacer(minLength: 0)
                Button("Find…", action: workspace.beginFindEntitlement)
                    .disabled(!navigationAllowed || !workspace.canFindEntitlement)
                Button("Previous Change", systemImage: "chevron.up") { workspace.moveToChange(.previous) }
                    .labelStyle(.iconOnly).help("Previous Change")
                    .disabled(!navigationAllowed || !workspace.canMoveToChange(.previous))
                Button("Next Change", systemImage: "chevron.down") { workspace.moveToChange(.next) }
                    .labelStyle(.iconOnly).help("Next Change")
                    .disabled(!navigationAllowed || !workspace.canMoveToChange(.next))
                Menu {
                    Button("Reset View") { model.browser.reset() }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }.controlSize(.small).padding(.horizontal, AppDesign.Space.section).padding(.top, AppDesign.Space.medium)
            HStack {
                Text("\(model.browser.visibleRows.count) keys shown · \(model.browser.count(.allChanges)) changes")
                Spacer()
                Text(model.browser.changePositionText).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, AppDesign.Space.section)
            if let guidance = model.browser.recoveryGuidance {
                EntitlementsRecoveryView(guidance: guidance,
                    disabled: !navigationAllowed || workspace.isBusy,
                    recover: { model.browser.recover($0) })
            } else {
                GeometryReader { geometry in
                    VSplitView {
                        ChangeTable(rows: model.browser.visibleRows, selection: $model.browser.selection,
                                    sortOrder: $model.browser.sortOrder, revealID: workspace.findRevealID,
                                    revealRevision: workspace.findRevealRevision)
                            .frame(minHeight: 100)
                        VStack(alignment: .leading, spacing: 6) {
                            if let row = model.browser.selectedRow { EntitlementReferenceView(key: row.key) }
                            detailView.id(model.reportRevision).id(model.browser.selectedRow?.id)
                        }.frame(minHeight: min(300, max(200, geometry.size.height * 0.55)))
                    }
                }
            }
        }
    }

    var detailView: ChangeDetailView {
        let model = workspace.model
        let revision = model.reportRevision
        return ChangeDetailView(change: model.browser.selectedRow, comparisonRevision: revision,
                    copy: { _ in workspace.copySelected() }, copyKey: { workspace.copyExactKey() },
                    inspect: { change, row in workspace.inspectValue(change, row: row, comparisonRevision: revision) },
                    copyBranch: { side, row, id, revision in
                        workspace.copyBranch(side, row: row, entitlementID: id, comparisonRevision: revision)
                    },
                    openTreeHit: { workspace.openTreeHit($0, hit: $1) },
                    copyTreeResult: { workspace.copyTreeResultDetails($0) },
                    openTreeHexHit: { workspace.openTreeHexHit($0, hit: $1) },
                    copyTreeHexResult: { workspace.copyTreeHexResultDetails($0) }, busy: workspace.isBusy)

    }
}

private struct EntitlementsRecoveryView: View {
    let guidance: BrowserRecoveryGuidance
    let disabled: Bool
    let recover: (BrowserRecoveryGuidance.Action) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Space.medium) {
                Text(guidance.title).font(.headline)
                Text(guidance.message).foregroundStyle(.secondary)
                if let action = guidance.action, let label = guidance.actionLabel {
                    Button(label) { recover(action) }.disabled(disabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppDesign.Space.section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct EntitlementsEmptyView: View {
    @Bindable var workspace: EntitlementsWorkspace
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = workspace.model.reportError {
                    LumenBanner(error, tone: .warning)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: AppDesign.Space.medium) {
                    LumenEmptyState(systemImage: "square.split.2x1", title: "Inspect one app or compare two builds",
                        message: "Choose or drop one app into either input to browse its typed entitlements. Load the other input to compare both captured dictionaries for the selected architecture.")
                    HStack(spacing: 8) {
                        Button("Open Saved Comparison…", action: workspace.chooseSavedReport)
                        Button("Load Example", action: workspace.loadExample)
                        Spacer()
                    }.disabled(workspace.isBusy)
                }
                HStack(alignment: .top, spacing: 16) {
                    SectionCard("Typed evidence") {
                        Text("Inspect added, removed and changed keys, then select a row to compare its exact values. Missing and explicitly empty dictionaries remain distinct.")
                            .foregroundStyle(.secondary)
                    }
                    SectionCard("Explicit batch work") {
                        Text("Use Comparison Queue in the sidebar for ordered app pairs and portable manifests. Import previews selections; running is always a separate action.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.padding(AppDesign.Space.page)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
