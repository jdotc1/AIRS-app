import EntitlementDiffModel
import SwiftUI
import EntitlementDiffCore

struct TreeTextSearchView: View {
    @Bindable var session: TreeTextSearchSession
    let open: (EntitlementTreeSearch.Hit) -> Void
    let copy: () -> Void
    let busy: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ExactKeyField(input: Binding(get: { session.input }, set: { session.setQuery($0) }),
                              placeholder: "Find text in string values", submit: { session.search() }, edited: {})
                    .frame(height: 24)
                Button("Search Tree") { session.search() }.disabled(session.running || busy)
                Button("Continue Tree Search") { session.advance() }
                    .disabled(session.running || busy || session.cursor == nil || session.cursor?.complete == true || session.cursor?.limited == true)
            }
            HStack {
                Picker("Search in", selection: Binding(get: { session.scope }, set: { session.setScope($0) })) {
                    ForEach(EntitlementTreeSearch.Scope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }.frame(maxWidth: 260).disabled(busy)
                Button("Clear Tree Search") { session.clear() }
                    .disabled(busy || !session.canClear)
            }
            Text(session.message).font(.caption).foregroundStyle(.secondary)
            Text("Literal UTF-8 · first match per string leaf · 64 traversal operations and one 32 KiB string portion per action · up to 200 results. Data and other value types are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Previous Result") { session.previousResult() }
                    .disabled(busy || !session.canSelectPrevious)
                Button("Next Result") { session.nextResult() }
                    .disabled(busy || !session.canSelectNext)
                Text(session.positionLabel).font(.caption)
                Spacer()
                Button("Open Selected Match…") {
                    if let hit = session.selectedHit { open(hit) }
                }.disabled(busy || session.running || session.selectedHit == nil)
            }
            HStack {
                TextField("Result number (1-based)", text: Binding(get: { session.resultInput }, set: { session.setResultInput($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .disabled(busy || !session.canGoToResult)
                    .onSubmit { if !busy { session.goToResult() } }
                Button("Go to Result") { session.goToResult() }
                    .disabled(busy || !session.canGoToResult)
                Text("Jump within results found so far.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.resultInputError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("Copy Selected Result Details", action: copy)
                .disabled(busy || session.running || session.selectedHit == nil)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.cursor?.hits ?? []) { hit in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(verbatim: hit.side.label + " · " + hit.pathPreview).lineLimit(3)
                                Text("Match at UTF-8 byte \(hit.match.byteOffset + 1), scalar \(hit.match.scalarOffset + 1) · \(hit.queryByteCount) query bytes")
                                    .font(.caption)
                                if let preview = hit.contextPreview {
                                    Text(verbatim: "Context preview · ⟦match⟧: " + preview)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(3)
                                }
                            }
                            Spacer()
                            Button(session.selectedHitID == hit.id ? "Selected" : "Select") { session.selectHit(hit.id) }
                                .disabled(busy || session.running)
                            Button("Open Match…") { session.selectHit(hit.id); open(hit) }.disabled(busy || session.running)
                        }
                        .padding(6)
                        .background(session.selectedHitID == hit.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .id(hit.id)
                    }
                }
            }
            .onChange(of: session.resultRevealRevision) { _, _ in
                if let id = session.selectedHitID { proxy.scrollTo(id, anchor: .center) }
            }
            }
        }
        .frame(minHeight: 280)
        .onDisappear { session.cancel() }
    }
}
