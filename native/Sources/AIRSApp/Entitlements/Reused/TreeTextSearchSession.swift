import EntitlementDiffModel
import Foundation
import Observation
import EntitlementDiffCore

@MainActor @Observable final class TreeTextSearchSession {
    let selectionID: String
    let comparisonRevision: UUID
    private let previous: EntitlementValue?
    private let current: EntitlementValue?
    private(set) var scope: EntitlementTreeSearch.Scope = .both
    private(set) var input = ExactKeyInput()
    private(set) var cursor: EntitlementTreeSearch?
    private(set) var selectedHitID: UUID?
    private(set) var resultInput = ""
    private(set) var resultInputError: String?
    private(set) var resultRevealRevision = UUID()
    var canGoToResult: Bool { !running && !(cursor?.hits.isEmpty ?? true) }
    func setResultInput(_ text: String) {
        resultInput = String(decoding: text.utf8.prefix(21), as: UTF8.self)
        resultInputError = nil
    }
    func goToResult() {
        guard canGoToResult, let hits = cursor?.hits else { return }
        let bytes = Array(resultInput.utf8.prefix(21))
        guard !bytes.isEmpty, bytes.count <= 20,
              bytes.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let number = Int(resultInput), number >= 1, number <= hits.count else {
            resultInputError = "Enter a result number from 1 through \(hits.count) found so far."
            return
        }
        selectHit(hits[number - 1].id)
    }
    private func resetResultInput() { resultInput = ""; resultInputError = nil }
    var selectedIndex: Int? { cursor?.hits.firstIndex { $0.id == selectedHitID } }
    var selectedHit: EntitlementTreeSearch.Hit? {
        guard let index = selectedIndex else { return nil }
        return cursor?.hits[index]
    }
    var canSelectPrevious: Bool { !running && (selectedIndex ?? 0) > 0 }
    var canSelectNext: Bool {
        !running && (selectedIndex.map { $0 + 1 } ?? 0) < (cursor?.hits.count ?? 0)
    }
    var positionLabel: String {
        guard let index = selectedIndex else { return "No result selected." }
        return "Result \(index + 1) of \(cursor?.hits.count ?? 0) found."
    }
    func selectHit(_ id: UUID) {
        guard !running, cursor?.hits.contains(where: { $0.id == id }) == true else { return }
        selectedHitID = id
        resultInput = String((selectedIndex ?? 0) + 1)
        resultInputError = nil
        resultRevealRevision = UUID()
    }
    func previousResult() {
        guard canSelectPrevious, let index = selectedIndex else { return }
        if let hit = cursor?.hits[index - 1] { selectHit(hit.id) }
    }
    func nextResult() {
        guard canSelectNext else { return }
        if let hit = cursor?.hits[selectedIndex.map { $0 + 1 } ?? 0] { selectHit(hit.id) }
    }
    private(set) var running = false
    private(set) var message = "Search string values. First occurrence per leaf; Previous then Current."
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    typealias Runner = @Sendable (EntitlementTreeSearch) async throws -> EntitlementTreeSearch
    @ObservationIgnored private let runner: Runner
    init(change: EntitlementChange, revision: UUID, runner: Runner? = nil) {
        selectionID = change.id; comparisonRevision = revision
        previous = change.previous; current = change.current
        self.runner = runner ?? { cursor in
            let work = Task.detached { var next = cursor; try next.step(); return next }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
    }
    func setScope(_ value: EntitlementTreeSearch.Scope) {
        guard value != scope else { return }
        resetResultInput(); cancel(); scope = value; cursor = nil; selectedHitID = nil
        message = "Scope changed to \(value.rawValue). Use Search Tree."
    }
    func setQuery(_ value: ExactKeyInput) {
        let bounded = ExactKeyInput(value: String(decoding: value.value.utf8.prefix(1025), as: UTF8.self))
        guard input != bounded else { return }
        resetResultInput(); cancel(); selectedHitID = nil; input = bounded; cursor = nil; message = "Query changed. Use Search Tree."
    }
    var canClear: Bool { running || cursor != nil || selectedHitID != nil || !input.value.isEmpty }
    func clear() {
        resetResultInput(); cancel()
        input = ExactKeyInput()
        cursor = nil
        selectedHitID = nil
        message = "Search cleared. Enter text and use Search Tree."
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; running = false }
    @discardableResult func search() -> Task<Void, Never>? {
        resetResultInput(); cancel(); selectedHitID = nil
        do { cursor = try EntitlementTreeSearch(previous: previous, current: current, query: input.value, scope: scope) }
        catch { cursor = nil; message = "Enter 1–1,024 UTF-8 query bytes."; return nil }
        return advance()
    }
    @discardableResult func advance() -> Task<Void, Never>? {
        guard !running, let cursor, !cursor.complete, !cursor.limited else { return nil }
        running = true; let request = generation, runner = runner
        let work = Task { [weak self] in
            do {
                let next = try await runner(cursor)
                guard let self, !Task.isCancelled, request == self.generation else { return }
                self.cursor = next; self.running = false
                self.message = "\(next.scope.rawValue) scope · " + (next.limited ? "Search incomplete: result limit 200 or path depth limit 128 reached. Narrow the query or browse branches." : next.complete ? "Search complete. \(next.hits.count) matching string leaves." : "Search incomplete. \(next.visited) nodes visited; \(next.hits.count) matching leaves. Continue to search further.")
            } catch {
                guard let self, request == self.generation else { return }
                self.running = false; self.message = "Search did not complete. Use Search Tree to restart."
            }
        }
        task = work; return work
    }
}
