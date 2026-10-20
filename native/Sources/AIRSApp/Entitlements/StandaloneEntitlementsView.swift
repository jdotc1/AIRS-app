import SwiftUI
import LumenUI
import EntitlementDiffCore
import EntitlementDiffModel

/// One captured input remains one input. No comparison report or change statuses
/// are constructed to enable browsing.
struct StandaloneEntitlementsView: View {
    let input: StandaloneEntitlementInspection
    let disabled: Bool
    @State private var browser: StandaloneEntitlementBrowser

    init(input: StandaloneEntitlementInspection, disabled: Bool) {
        self.input = input
        self.disabled = disabled
        _browser = State(initialValue: StandaloneEntitlementBrowser(input: input))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.medium) {
            Text("Browsing \(input.side.label) input · \(DisplayText.escaped(input.snapshot.sourceName)) · \(input.snapshot.architecture.rawValue)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if input.snapshot.isSavedBaseline {
                Text("Saved report snapshot — unverified metadata; no new app inspection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if input.snapshot.origin == .syntheticExample {
                Text("Synthetic example data; no app was inspected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if input.entries.isEmpty {
                LumenEmptyState(systemImage: "list.bullet.rectangle", title: "No entitlement keys",
                                message: input.emptyMessage)
            } else {
                HStack {
                    TextField("Filter entitlement keys", text: Binding(
                        get: { browser.query },
                        set: { browser.query = String($0.unicodeScalars.prefix(256)) }
                    ))
                    .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 300)
                    Button("Clear Search") { browser.query = "" }.disabled(browser.query.isEmpty)
                    Spacer()
                    Text("\(browser.visibleEntries.count) of \(input.entries.count) keys")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.fixedSize(horizontal: false, vertical: true)
                if browser.visibleEntries.isEmpty {
                    LumenEmptyState(systemImage: "magnifyingglass", title: "No matching entitlement keys",
                                    message: "Clear Search to return to the captured keys.")
                } else {
                    GeometryReader { geometry in
                    VSplitView {
                        Table(browser.visibleEntries, selection: $browser.selection) {
                            TableColumn("Key") { entry in
                                Text(entry.keyPreview).font(.system(.body, design: .monospaced))
                            }.width(min: 180, ideal: 300)
                            TableColumn("Type", value: \.typeName).width(min: 60, ideal: 90, max: 120)
                            TableColumn("Value") { entry in
                                Text(entry.valuePreview).font(.system(.body, design: .monospaced))
                            }.width(min: 140, ideal: 240)
                        }
                        .frame(minHeight: min(100, max(0, geometry.size.height * 0.4)))
                        if let entry = browser.selectedEntry {
                            ScrollView {
                                StandaloneValueBrowser(entry: entry, side: input.side)
                                    .id(browser.input.id + ":" + entry.id)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }.frame(minHeight: min(140, max(0, geometry.size.height * 0.5)))
                        } else {
                            Text("Select a key to inspect its typed value.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.top, AppDesign.Space.regular)
                                .frame(minHeight: min(140, max(0, geometry.size.height * 0.5)))
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            Text("Single-input inspection. Load the other input above to compare two captured snapshots.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppDesign.Space.section)
        .padding(.vertical, AppDesign.Space.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(disabled)
        .onChange(of: input.id) { _, _ in browser.replaceInput(input) }
        // Future capture integration should use input.snapshot and input.revision,
        // validate that revision at publication, and use InspectionDocumentCodec.
        // This projection must never be serialized as a comparison report.
    }
}

private struct StandaloneValueBrowser: View {
    let entry: StandaloneEntitlementEntry
    @State private var navigator: StandaloneValueNavigator
    @State private var focusedLeaf: StandaloneValueRow?
    @State private var arrayIndex = ""
    @State private var indexError = false
    @State private var childInput = ExactKeyInput()
    @State private var childMissing = false

    init(entry: StandaloneEntitlementEntry, side: ComparisonSide) {
        self.entry = entry
        _navigator = State(initialValue: StandaloneValueNavigator(value: entry.value, side: side))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.regular) {
            Text(entry.keyPreview).font(.headline).lineLimit(3).textSelection(.enabled)
            EntitlementReferenceView(key: entry.key)
            if let leaf = navigator.root.leaf {
                StandaloneLeafValuePane(leaf: leaf)
            } else if let focusedLeaf, let leaf = focusedLeaf.leaf {
                HStack {
                    Button("Back to Branch") { self.focusedLeaf = nil }
                    Text(focusedLeaf.displayPath).font(.caption).lineLimit(2).textSelection(.enabled)
                }
                StandaloneLeafValuePane(leaf: leaf).id(focusedLeaf.id)
            } else {
                branchView
            }
        }
        .padding(.top, AppDesign.Space.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var branchView: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.medium) {
            HStack {
                Button("Up") { navigator.back(); resetLookup() }.disabled(!navigator.canGoBack)
                Button("Root") { navigator.goToRoot(); resetLookup() }.disabled(!navigator.canGoBack)
                Text("Level \(navigator.depth) · \(navigator.root.value.typeName)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("First") { navigator.firstPage(); resetLookup() }.disabled(!navigator.hasPrevious)
                Button("Previous") { navigator.previousPage(); resetLookup() }.disabled(!navigator.hasPrevious)
                Button("Next") { navigator.nextPage(); resetLookup() }.disabled(!navigator.hasNext)
            }
            Text("Path (tail preview): \(navigator.root.displayPath)")
                .font(.caption).lineLimit(2).textSelection(.enabled)
            if let count = navigator.arrayCount {
                HStack {
                    TextField("Array index", text: $arrayIndex).textFieldStyle(.roundedBorder).frame(width: 110)
                    Button("Go to Index") {
                        guard let index = Int(arrayIndex), navigator.goToArrayIndex(index) else {
                            indexError = true; return
                        }
                        indexError = false
                    }
                    Text(indexError ? "Choose an existing zero-based index." : "\(count) array slots")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if navigator.canFindChildKey {
                HStack {
                    ExactKeyField(input: $childInput) {
                        navigator.clearExactChild(); childMissing = false
                    }.frame(height: 24)
                    Button("Find Child Key") { childMissing = !navigator.findExactChild(childInput.value) }
                    Button("Clear Lookup", action: resetLookup)
                }
                Text(childMissing
                    ? "No exact child key in this dictionary."
                    : "Exact UTF-8 lookup in this dictionary only; enter the raw key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesign.Space.regular) {
                    if let exact = navigator.exactChild {
                        Text("Exact child match").font(.caption)
                        valueRow(exact)
                        Divider()
                    }
                    ForEach(navigator.rows) { valueRow($0) }
                    if navigator.rows.isEmpty {
                        Text("This container has no child values.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(navigator.root.id + ":" + String(navigator.offset))
            Text("50 immediate children per page. Branch navigation does not search descendants. Value previews are bounded; View Value opens the complete scalar in pages.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func valueRow(_ row: StandaloneValueRow) -> some View {
        HStack(alignment: .top, spacing: AppDesign.Space.regular) {
            VStack(alignment: .leading, spacing: AppDesign.Space.small) {
                Text(row.label).lineLimit(3).textSelection(.enabled)
                Text("\(row.value.typeName) · \(row.value.preview(maxCharacters: 160))")
                    .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }.font(.system(.caption, design: .monospaced))
            Spacer()
            if row.isContainer {
                Button("Open Branch") { _ = navigator.enter(row.id); resetLookup() }
            } else {
                Button("View Value") { focusedLeaf = row }
            }
        }
    }

    private func resetLookup() {
        arrayIndex = ""; indexError = false
        childInput = ExactKeyInput(); childMissing = false; navigator.clearExactChild()
    }
}

/// Reuses the existing cancellable scalar paging implementation. A standalone
/// viewer has no opposite-side placeholder or comparison controls.
private struct StandaloneLeafValuePane: View {
    let leaf: InspectorLeaf
    @State private var document: LeafValueDocument?
    @State private var page = 0
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.regular) {
            Text(leaf.value.typeName).font(.caption.weight(.semibold))
            if let document {
                ScrollView([.horizontal, .vertical]) {
                    Text(document.text(onPage: page))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                HStack {
                    Button("First") { page = 0 }.disabled(page == 0)
                    Button("Previous") { page = max(0, page - 1) }.disabled(page == 0)
                    Text("Page \(page + 1) of \(document.pageCount)").font(.caption).monospacedDigit()
                    Button("Next") { page = min(document.pageCount - 1, page + 1) }
                        .disabled(page + 1 >= document.pageCount)
                    Button("Last") { page = document.pageCount - 1 }
                        .disabled(page + 1 >= document.pageCount)
                }
                if let count = document.stringScalarCount {
                    Text("\(count) Unicode scalars · 512 scalars per page · escaped display")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .data(let data) = leaf.value {
                    Text("\(data.count) bytes · 768 bytes per page · base64 display")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let failure {
                Text(DisplayText.escaped(failure)).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                ProgressView("Preparing captured value…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            let leaf = self.leaf
            let build = Task.detached(priority: .userInitiated) { try LeafValueDocument(leaf: leaf) }
            do {
                let loaded = try await withTaskCancellationHandler {
                    try await build.value
                } onCancel: {
                    build.cancel()
                }
                try Task.checkCancellation()
                document = loaded
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}
