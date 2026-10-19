import SwiftUI
import LumenUI
import EntitlementDiffCore
import EntitlementDiffModel

/// Immutable values captured by an explicit row action, not resolved from truncated labels.
struct FocusedValueSelection: Identifiable {
    let id = UUID()
    let entitlementKey: String
    let pathPreview: String
    let previous: EntitlementValue?
    let current: EntitlementValue?
    var initialSide: ComparisonSide? = nil
    var initialByte: Int? = nil
    var initialScalar: Int? = nil
    var initialMatchRange: Range<Int>? = nil

    func value(for side: ComparisonSide) -> EntitlementValue? {
        side == .previous ? previous : current
    }
}

struct FocusedValueView: View {
    let selection: FocusedValueSelection
    @Bindable var actions: EntitlementsWorkspace
    @State private var difference: FocusedStringDifference?
    @State private var dataDifference: FocusedDataDifference?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppDialogTitle(title: "Focused Value")
            Divider()
            Text(EntitlementValue.string(selection.entitlementKey).preview(maxCharacters: 512))
                .font(.system(.headline, design: .monospaced)).textSelection(.enabled)
            Text("Path (preview): \(EntitlementValue.string(selection.pathPreview).preview(maxCharacters: 512))")
                .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if let difference {
                HStack {
                    Button(difference.phase == .paused ? "Continue Comparison" : "Find First Difference") {
                        if difference.phase == .paused { difference.advance() } else { difference.find() }
                    }
                    .disabled(difference.phase == .running)
                    if difference.position != nil {
                        Button("Previous Found Difference") { difference.previousFound() }.disabled(!difference.canPrevious)
                        Button("Find Next Difference") { difference.next() }.disabled(!difference.canNext)
                        Button("Reveal Difference") { difference.reveal() }
                    }
                    if difference.phase == .running { ProgressView().controlSize(.small) }
                }
                if let range = difference.foundRange {
                    FoundDifferenceJumpView(input: Binding(get: { difference.jumpInput }, set: { difference.setJumpInput($0) }),
                                            range: range, error: difference.jumpError, enabled: difference.canJump,
                                            go: { difference.jumpToFound() },
                                            copy: { actions.copyDifferenceDetails(difference.copyDetails, selectionID: selection.id) })
                }
                if let notice = difference.historyNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text(difference.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dataDifference {
                HStack {
                    Button(dataDifference.phase == .paused ? "Continue Comparison" : "Find First Difference") {
                        if dataDifference.phase == .paused { dataDifference.advance() } else { dataDifference.find() }
                    }
                    .disabled(dataDifference.phase == .running)
                    if dataDifference.position != nil {
                        Button("Previous Found Difference") { dataDifference.previousFound() }.disabled(!dataDifference.canPrevious)
                        Button("Find Next Difference") { dataDifference.next() }.disabled(!dataDifference.canNext)
                        Button("Reveal Difference") { dataDifference.reveal() }
                    }
                    if dataDifference.phase == .running { ProgressView().controlSize(.small) }
                }
                if let range = dataDifference.foundRange {
                    FoundDifferenceJumpView(input: Binding(get: { dataDifference.jumpInput }, set: { dataDifference.setJumpInput($0) }),
                                            range: range, error: dataDifference.jumpError, enabled: dataDifference.canJump,
                                            go: { dataDifference.jumpToFound() },
                                            copy: { actions.copyDifferenceDetails(dataDifference.copyDetails, selectionID: selection.id) })
                }
                if let notice = dataDifference.historyNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text(dataDifference.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(ComparisonSide.allCases, id: \.self) { side in
                    LeafValuePane(side: side, value: selection.value(for: side),
                                  excludedBySearch: selection.initialSide != nil && selection.initialSide != side,
                                  initialByte: selection.initialSide == side ? selection.initialByte : nil,
                                  initialScalar: selection.initialSide == side ? selection.initialScalar : nil,
                                  initialMatchRange: selection.initialSide == side ? selection.initialMatchRange : nil,
                                  copyScalarDetails: { actions.copyScalarDetails($0, side: side, selectionID: selection.id) },
                                  copyByteContext: { actions.copyByteContext($0, side: side, selectionID: selection.id) },
                                  copyHexMatch: { actions.copyHexMatchDetails($0, side: side, selectionID: selection.id) },
                                  copyTextMatch: { actions.copyTextMatchDetails($0, side: side, selectionID: selection.id) },
                                  copying: actions.isWorking, copy: { actions.copyLeaf(side) },
                                  differencePosition: difference?.position, differenceRevision: difference?.revision,
                                  dataDifferencePosition: dataDifference?.position, dataDifferenceRevision: dataDifference?.revision,
                                  dataContext: side == .previous ? dataDifference?.previousContext : dataDifference?.currentContext)
                }
            }
            Text("Values are captured when opened. Strings escape control characters; data is base64. Copy Leaf JSON includes the complete typed value, regardless of the page.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if actions.isWorking { ProgressView().controlSize(.small) }
                Text(DisplayText.escaped(actions.status)).font(.caption).lineLimit(3)
                Spacer()
                Button("Done") { actions.focusedValue = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(actions.isWorking)
            }
        }
        .padding(AppDesign.Space.page)
        .frame(minWidth: 880, idealWidth: 880, minHeight: 800, idealHeight: 800)
        .appDialogSurface()
        .interactiveDismissDisabled(actions.isWorking)
        .task(id: selection.id) {
            difference?.cancel(); dataDifference?.cancel()
            if case .string(let previous) = selection.previous, case .string(let current) = selection.current {
                difference = FocusedStringDifference(previous: previous, current: current)
            } else { difference = nil }
            if case .data(let previous) = selection.previous, case .data(let current) = selection.current {
                dataDifference = FocusedDataDifference(previous: previous, current: current)
            } else { dataDifference = nil }
        }
        .onDisappear { difference?.cancel(); dataDifference?.cancel() }
    }
}

private struct LeafValuePane: View {
    @Environment(\.lumenPalette) private var palette

    let side: ComparisonSide
    let value: EntitlementValue?
    let excludedBySearch: Bool
    let initialByte: Int?
    let initialScalar: Int?
    let initialMatchRange: Range<Int>?
    @State private var showingTreeMatch = true
    let copyScalarDetails: (StringScalarNavigation) -> Void
    let copyByteContext: (DataByteNavigation) -> Void
    let copyHexMatch: (FocusedHexSearch) -> Void
    let copyTextMatch: (FocusedStringSearch) -> Void
    let copying: Bool
    let copy: () -> Void
    let differencePosition: StringFirstDifference.Position?
    let differenceRevision: UUID?
    let dataDifferencePosition: DataFirstDifference.Position?
    let dataDifferenceRevision: UUID?
    let dataContext: DataDifferenceContext?
    @State private var scalarNavigation = StringScalarNavigation()
    @State private var byteNavigation = DataByteNavigation()
    @State private var showingDifference = false
    @State private var showingTextMatch = false
    @State private var document: LeafValueDocument?
    @State private var navigation = LeafPageNavigation()
    @State private var preparationError: String?
    @State private var search: FocusedStringSearch?
    @State private var hexSearch: FocusedHexSearch?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(side.label).font(.headline)
            Text(excludedBySearch ? "Not captured" : value?.typeName ?? "Absent").foregroundStyle(.secondary)
            if let position = differencePosition {
                let detail = side == .previous ? position.previousDetail : position.currentDetail
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Difference: " + detail.scalarLabel).font(.system(.caption, design: .monospaced))
                    if let bytes = detail.utf8Bytes {
                        Text("UTF-8: \(bytes)").font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption).textSelection(.enabled)
            }
            if let position = dataDifferencePosition {
                let byte = side == .previous ? position.previousByte : position.currentByte
                Text(byte == nil ? "Difference: End of data" :
                     "Difference byte: " + (side == .previous ? position.previousLabel : position.currentLabel))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if case .data(let data) = value {
                HStack {
                    Text("Go to byte (1-based)").font(.caption)
                    TextField("\(side.label) byte position", text: Binding(
                        get: { byteNavigation.input }, set: { byteNavigation.setInput($0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                        .onSubmit { goToByte(data) }
                    Button("Go to Byte") { goToByte(data) }
                    if byteNavigation.byteOffset != nil { Button("Reveal Byte") { revealByte() } }
                }
                if let error = byteNavigation.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let context = byteNavigation.context {
                    Text("Manual byte context · selected difference unchanged").font(.caption).foregroundStyle(.secondary)
                    DataHexContextView(context: context)
                    HStack {
                        Button("Previous Byte") { stepByte(.previous, data) }
                            .disabled(!byteNavigation.canStep(.previous, dataCount: data.count))
                        Button("Next Byte") { stepByte(.next, data) }
                            .disabled(!byteNavigation.canStep(.next, dataCount: data.count))
                        Button("Copy Byte Context") { copyByteContext(byteNavigation) }
                            .disabled(copying)
                    }
                } else if let dataContext { DataHexContextView(context: dataContext) }
            }
            if let document {
                if document.stringScalarCount != nil {
                    HStack {
                        Text("Go to scalar (1-based)").font(.caption)
                        TextField("\(side.label) scalar position", text: Binding(
                            get: { scalarNavigation.input }, set: { scalarNavigation.setInput($0) }))
                            .textFieldStyle(.roundedBorder).frame(width: 90)
                            .onSubmit { goToScalar(document) }
                        Button("Go to Scalar") { goToScalar(document) }
                        if scalarNavigation.position != nil { Button("Reveal Scalar") { revealScalar(document) } }
                    }
                    .disabled(search?.phase == .running)
                    if let error = scalarNavigation.error {
                        Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let position = scalarNavigation.position {
                        Text("Manual scalar \(position.scalarOffset + 1) · UTF-8 byte \(position.byteOffset + 1) · difference/search unchanged")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: position.detail.scalarLabel + " · UTF-8: " + (position.detail.utf8Bytes ?? "EOF"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("Previous Scalar") { stepScalar(.previous, document) }
                                .disabled(search?.phase == .running || !scalarNavigation.canStep(.previous, document: document))
                            Button("Next Scalar") { stepScalar(.next, document) }
                                .disabled(search?.phase == .running || !scalarNavigation.canStep(.next, document: document))
                            Button("Copy Scalar Details") { copyScalarDetails(scalarNavigation) }
                                .disabled(copying)
                        }
                    }
                }
                if let page = stringPage(document) {
                    HighlightedStringPageView(page: page, pageIndex: navigation.index,
                                              revealRevision: showingTextMatch ? search?.revealRevision :
                                                scalarNavigation.position != nil ? scalarNavigation.revision :
                                                (showingDifference ? differenceRevision : search?.matchRevision))
                        .frame(minHeight: 80)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette[.bgInset], in: RoundedRectangle(cornerRadius: AppDesign.Layout.radius))
                    if page.continuesBefore || page.continuesAfter {
                        Text(page.continuesBefore && page.continuesAfter ? "Match continues from the previous page and onto the next." :
                             page.continuesBefore ? "Match continues from the previous page." : "Match continues onto the next page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HighlightedStringPageView(text: document.text(onPage: navigation.index),
                                              pageIndex: navigation.index, revealRevision: dataDifferenceRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette[.bgInset], in: RoundedRectangle(cornerRadius: AppDesign.Layout.radius))
                    .id(DataPageIdentity(page: navigation.index, revision: dataDifferenceRevision))
                }
                if showingDifference, let position = differencePosition,
                   byteCount(position) == 0, navigation.index == document.pageCount - 1 {
                    Text("End of string at difference (closing quote marked).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Page \(navigation.index + 1) of \(document.pageCount)").font(.caption).monospacedDigit()
                HStack {
                    Button("First") { navigation.select(0, pageCount: document.pageCount) }.disabled(navigation.index == 0)
                    Button("Previous") { navigation.select(navigation.index - 1, pageCount: document.pageCount) }.disabled(navigation.index == 0)
                    Button("Next") { navigation.select(navigation.index + 1, pageCount: document.pageCount) }.disabled(navigation.index + 1 == document.pageCount)
                    Button("Last") { navigation.select(document.pageCount - 1, pageCount: document.pageCount) }.disabled(navigation.index + 1 == document.pageCount)
                }
                HStack {
                    TextField("Page number", text: $navigation.input)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                        .onSubmit { navigation.go(pageCount: document.pageCount) }
                    Button("Go") { navigation.go(pageCount: document.pageCount) }
                    Text("1–\(document.pageCount)").font(.caption).foregroundStyle(.secondary)
                }
                if navigation.isInvalid {
                    Text("Enter a whole page number from 1 through \(document.pageCount).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if InspectorLeaf(value) != nil {
                if let preparationError {
                    Text(DisplayText.escaped(preparationError))
                } else {
                    ProgressView("Preparing value…")
                }
                Spacer()
            } else {
                Text(excludedBySearch ? "This result captures the other side only. Open a separate result to inspect this side." : value == nil ? "No value on this side." : "This side is a container. Choose one of its nested values in the inspector.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let search {
                HStack {
                    ExactKeyField(input: Binding(get: { search.input }, set: { search.setQuery($0) }),
                                  placeholder: "Find literal text", submit: { search.find() }, edited: {})
                        .frame(height: 24)
                    Button("Find") { search.find() }
                    Button("Clear Text Search") { search.clear() }
                }
                HStack {
                    Button(search.phase == .paused && search.direction == .backward ? "Continue Backward" : "Find Previous") {
                        search.advance(direction: .backward)
                    }
                    .disabled(!search.canSearch(.backward))
                    Button(search.phase == .paused && search.direction == .forward ? "Continue Search" : "Find Next") {
                        search.advance(direction: .forward)
                    }
                    .disabled(!search.canSearch(.forward))
                    if search.phase == .running { ProgressView().controlSize(.small) }
                }
                Text(search.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if search.match != nil {
                    HStack {
                        Button("Reveal Text Match") { search.reveal() }.disabled(!search.canReveal)
                        Button("Copy Text Match Details") { copyTextMatch(search) }
                            .disabled(copying || !search.canReveal)
                    }
                }
            }
            if let hexSearch { HexSearchControls(search: hexSearch, copying: copying, copy: { copyHexMatch(hexSearch) }) }
            Button("Copy \(side.label) Leaf JSON", action: copy)
                .disabled(InspectorLeaf(value) == nil || copying)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: differenceRevision) { _, _ in revealDifference() }
        .onChange(of: dataDifferenceRevision) { _, _ in revealDataDifference() }
        .onChange(of: dataDifferencePosition) { _, position in
            if position == nil { byteNavigation.reset() }
        }
        .onChange(of: differencePosition) { _, position in
            if position == nil { showingDifference = false }
        }
        .onChange(of: search?.phase) { _, phase in
            if phase == .running { showingTreeMatch = false; showingTextMatch = false; showingDifference = false; scalarNavigation.reset() }
        }
        .onChange(of: search?.matchRevision) { _, _ in
            if let page = search?.match?.pageIndex, let document {
                showingTreeMatch = false; showingTextMatch = false; showingDifference = false; scalarNavigation.reset()
                navigation.select(page, pageCount: document.pageCount)
            }
        }
        .onChange(of: search?.revealRevision) { _, _ in
            if let search, search.canReveal, let page = search.match?.pageIndex, let document {
                showingTextMatch = true; showingDifference = false
                navigation.select(page, pageCount: document.pageCount)
            }
        }
        .onChange(of: search?.matchByteRange) { _, range in
            if range == nil { showingTextMatch = false }
        }
        .onChange(of: hexSearch?.revision) { _, _ in
            if let offset = hexSearch?.matchOffset, let document {
                navigation.select(offset / LeafValueDocument.dataBytesPerPage, pageCount: document.pageCount)
            }
        }
        .onDisappear { search?.cancel(); hexSearch?.cancel() }
        .task {
            guard let leaf = InspectorLeaf(value) else { return }
            let work = Task.detached(priority: .userInitiated) { try LeafValueDocument(leaf: leaf) }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                document = prepared
                revealDifference(); revealDataDifference()
                if case .string(let text) = leaf.value { search = FocusedStringSearch(source: text) }
                if case .data(let bytes) = leaf.value { hexSearch = FocusedHexSearch(source: bytes) }
                if let initialByte, case .data(let bytes) = leaf.value {
                    byteNavigation.setInput(String(initialByte))
                    goToByte(bytes)
                }
                if let initialScalar {
                    scalarNavigation.setInput(String(initialScalar))
                    goToScalar(prepared)
                    showingTreeMatch = true
                }
            } catch is CancellationError {
                // The sheet was dismissed; never publish a late preparation result.
            } catch {
                preparationError = error.localizedDescription
            }
        }
    }

    private func stepScalar(_ direction: StringScalarNavigation.Direction, _ document: LeafValueDocument) {
        guard search?.phase != .running, scalarNavigation.step(direction, document: document),
              let position = scalarNavigation.position else { return }
        showingTreeMatch = false; showingTextMatch = false; showingDifference = false
        navigation.select(position.pageIndex, pageCount: document.pageCount)
    }

    private func revealScalar(_ document: LeafValueDocument) {
        guard search?.phase != .running, scalarNavigation.reveal(),
              let position = scalarNavigation.position else { return }
        showingTreeMatch = false; showingTextMatch = false; showingDifference = false
        navigation.select(position.pageIndex, pageCount: document.pageCount)
    }

    private func revealByte() {
        guard let document, byteNavigation.reveal(), let offset = byteNavigation.byteOffset else { return }
        navigation.select(min(offset / LeafValueDocument.dataBytesPerPage, document.pageCount - 1),
                          pageCount: document.pageCount)
    }

    private func goToScalar(_ document: LeafValueDocument) {
        guard search?.phase != .running, scalarNavigation.go(document: document),
              let position = scalarNavigation.position else { return }
        showingTreeMatch = false; showingTextMatch = false; showingDifference = false
        navigation.select(position.pageIndex, pageCount: document.pageCount)
    }

    private func stepByte(_ direction: DataByteNavigation.Direction, _ data: Data) {
        guard byteNavigation.step(direction, data: data), let offset = byteNavigation.byteOffset,
              let document else { return }
        navigation.select(min(offset / LeafValueDocument.dataBytesPerPage, document.pageCount - 1),
                          pageCount: document.pageCount)
    }

    private func goToByte(_ data: Data) {
        guard byteNavigation.go(data: data), let offset = byteNavigation.byteOffset,
              let document else { return }
        navigation.select(min(offset / LeafValueDocument.dataBytesPerPage, document.pageCount - 1),
                          pageCount: document.pageCount)
    }

    private func byteCount(_ position: StringFirstDifference.Position) -> Int {
        side == .previous ? position.previousByteCount : position.currentByteCount
    }
    private func stringPage(_ document: LeafValueDocument) -> LeafValueDocument.StringPage? {
        if showingTreeMatch, let initialMatchRange {
            return document.stringPage(onPage: navigation.index, matching: initialMatchRange)
        }
        if showingTextMatch, let range = search?.matchByteRange {
            return document.stringPage(onPage: navigation.index, matching: range)
        }
        if let position = scalarNavigation.position {
            return document.stringDifferencePage(onPage: navigation.index, byteOffset: position.byteOffset,
                                                 scalarByteCount: position.byteCount)
        }
        if showingDifference, let position = differencePosition {
            return document.stringDifferencePage(onPage: navigation.index, byteOffset: side == .previous ? position.previousByteOffset : position.currentByteOffset,
                                                 scalarByteCount: byteCount(position))
        }
        return document.stringPage(onPage: navigation.index, matching: search?.matchByteRange)
    }
    private func revealDifference() {
        showingTreeMatch = false
        showingTextMatch = false
        scalarNavigation.reset()
        guard let document, let position = differencePosition else { return }
        showingDifference = true
        navigation.select(min(position.pageIndex, document.pageCount - 1), pageCount: document.pageCount)
    }

    private func revealDataDifference() {
        byteNavigation.reset()
        guard let document, let position = dataDifferencePosition else { return }
        navigation.select(min(position.pageIndex, document.pageCount - 1), pageCount: document.pageCount)
    }

}


private struct DataPageIdentity: Hashable {
    let page: Int
    let revision: UUID?
}

private struct DataHexContextView: View {
    let context: DataDifferenceContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hex context").font(.caption.weight(.semibold))
            Text(verbatim: context.rangeLabel).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 1) {
                if !context.beforeHex.isEmpty { Text(verbatim: context.beforeHex) }
                Text(verbatim: context.markedHex).fontWeight(.semibold)
                if !context.afterHex.isEmpty { Text(verbatim: context.afterHex) }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FoundDifferenceJumpView: View {
    @Binding var input: String
    let range: String
    let error: String?
    let enabled: Bool
    let go: () -> Void
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Go to found difference")
                TextField("Difference number", text: $input)
                    .textFieldStyle(.roundedBorder).frame(width: 90).onSubmit(go)
                Button("Go", action: go)
                Text(verbatim: range).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy Difference Details", action: copy)
            }
            .disabled(!enabled)
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct HexSearchControls: View {
    @Bindable var search: FocusedHexSearch
    let copying: Bool
    let copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Find hex bytes", text: Binding(get: { search.query }, set: { search.setQuery($0) }))
                    .textFieldStyle(.roundedBorder).onSubmit { search.find() }
                Button("Find Hex") { search.find() }.disabled(search.phase == .running)
                Button("Clear Hex Search") { search.clear() }
            }
            HStack {
                Button(search.phase == .paused && search.direction == .backward ? "Continue Backward" : "Find Previous Hex") {
                    search.advance(direction: .backward)
                }
                .disabled(!search.canSearch(.backward))
                Button(search.phase == .paused && search.direction == .forward ? "Continue Hex Search" : "Find Next Hex") {
                    search.advance(direction: .forward)
                }
                .disabled(!search.canSearch(.forward))
                if search.phase == .running { ProgressView().controlSize(.small) }
            }
            Text(search.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let context = search.context {
                HStack {
                    Button("Reveal Hex Match") { search.reveal() }.disabled(!search.canReveal)
                    Button("Copy Hex Match Details", action: copy).disabled(copying || !search.canReveal)
                }
                Text(verbatim: context).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
