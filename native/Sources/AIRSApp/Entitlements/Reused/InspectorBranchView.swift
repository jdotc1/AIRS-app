import SwiftUI
import EntitlementDiffCore
import EntitlementDiffModel

struct InspectorBranchView: View {
    let change: EntitlementChange
    let inspect: (EntitlementChange, InspectorRow) -> Void
    let copyBranch: (ComparisonSide, InspectorRow) -> Void
    let close: () -> Void
    let busy: Bool
    @State private var navigation: InspectorBranchNavigator
    @State private var arrayIndex = ""
    @State private var indexError = false
    @State private var childInput = ExactKeyInput()
    @State private var childMissing = false

    init(change: EntitlementChange, inspect: @escaping (EntitlementChange, InspectorRow) -> Void,
         copyBranch: @escaping (ComparisonSide, InspectorRow) -> Void,
         close: @escaping () -> Void, busy: Bool) {
        self.copyBranch = copyBranch
        self.change = change; self.inspect = inspect; self.close = close; self.busy = busy
        _navigation = State(initialValue: InspectorBranchNavigator(previous: change.previous, current: change.current))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Button("Back to Search", action: close)
                    Button("Up") { navigation.back(); resetIndex() }.disabled(!navigation.canGoBack)
                    Button("Root") {
                        if let root = navigation.rootAncestor, navigation.jump(to: root) { resetIndex() }
                    }.disabled(!navigation.canGoBack)
                    Menu("Ancestors…") {
                        ForEach(navigation.recentAncestors) { ancestor in
                            Button("Level \(ancestor.level) · \(ancestor.label)") {
                                if navigation.jump(to: ancestor) { resetIndex() }
                            }
                        }
                    }.fixedSize().disabled(navigation.recentAncestors.isEmpty)
                    Text("Branch level \(navigation.depth)").font(.caption)
                    Spacer()
                }
                HStack {
                    Button("First Children") { navigation.firstPage(); resetIndex() }.disabled(!navigation.hasPrevious)
                    Button("Previous Children") { navigation.previousPage(); resetIndex() }.disabled(!navigation.hasPrevious)
                    Button("Next Children") { navigation.nextPage(); resetIndex() }.disabled(!navigation.hasNext)
                }
                Text("Path (tail preview): \(navigation.root.displayPath)")
                    .font(.caption).lineLimit(2).textSelection(.enabled)
                HStack {
                    Button("Copy Previous Branch JSON") { copyBranch(.previous, navigation.root) }
                        .disabled(BranchJSONValue(navigation.root.previous) == nil)
                    Button("Copy Current Branch JSON") { copyBranch(.current, navigation.root) }
                        .disabled(BranchJSONValue(navigation.root.current) == nil)
                }
                Text("Copies the complete chosen container, including children outside this page. Tagged value JSON, not a saved comparison report.")
                    .font(.caption).foregroundStyle(.secondary)
                if let count = navigation.arrayCount {
                    HStack {
                        TextField("Array index", text: $arrayIndex).textFieldStyle(.roundedBorder).frame(width: 125)
                        Button("Go to Index") {
                            guard let index = Int(arrayIndex), navigation.goToArrayIndex(index) else { indexError = true; return }
                            indexError = false
                        }
                        Text(indexError ? "Enter an index from 0 through \(max(0, count - 1))." : "\(count) array slots · zero-based indices")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if navigation.canFindChildKey {
                    HStack {
                        ExactKeyField(input: $childInput) {
                            navigation.clearExactChild(); childMissing = false
                        }.frame(height: 24)
                        Button("Find Child Key") { childMissing = !navigation.findExactChild(childInput.value) }
                        Button("Clear Lookup") { resetLookup() }
                            .disabled(childInput.value.isEmpty && navigation.exactChild == nil && !childMissing)
                    }
                    Text(childMissing ? "No exact child key in this branch. The current page is unchanged." : "Exact UTF-8 match in this dictionary only. Enter the raw key without JSON quotes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let match = navigation.exactChild {
                        Text("Exact child match · current page unchanged").font(.caption)
                        valueRow(match, isRoot: false)
                        Divider()
                    }
                }
                Group {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        valueRow(navigation.root, isRoot: true)
                        Divider()
                        ForEach(navigation.rows) { row in valueRow(row, isRoot: false) }
                    }
                }
                .id(navigation.root.id + ":" + String(navigation.offset))
                Text(navigation.rows.isEmpty ? "No child values in this branch." : "Children \(navigation.offset + 1)–\(navigation.offset + navigation.rows.count) · \(navigation.hasNext ? "more children remain" : "end of this branch")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("50 immediate children per step. Descendants are not searched or compared here; open a branch to continue. Search limits still apply in Back to Search. Copy Selected JSON remains complete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .id(navigation.root.id + ":" + String(navigation.offset))
        .disabled(busy)
    }

    private func valueRow(_ row: InspectorRow, isRoot: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack {
                Text(isRoot ? "Branch" : row.label).lineLimit(3).textSelection(.enabled)
                if !isRoot && row.hasContainerValue {
                    Button("Open Branch") { _ = navigation.enter(row.id); resetIndex() }
                }
                if row.hasLeafValue { Button("View Value…") { inspect(change, row) } }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("Previous: \(InspectorRow.summary(row.previous))").textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Current: \(InspectorRow.summary(row.current))").textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(.caption, design: .monospaced))
    }

    private func resetLookup() {
        childInput = ExactKeyInput(); childMissing = false; navigation.clearExactChild()
    }
    private func resetIndex() { arrayIndex = ""; indexError = false; resetLookup() }
}
