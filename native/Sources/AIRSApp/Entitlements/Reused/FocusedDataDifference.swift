import Foundation
import Observation
import EntitlementDiffCore

@MainActor @Observable
final class FocusedDataDifference {
    enum Phase { case ready, running, paused, different, equal, finished, failed }
    typealias Runner = @Sendable (DataFirstDifference) async throws -> (DataFirstDifference, DataFirstDifference.Step)
    private(set) var phase: Phase = .ready
    private(set) var differenceCount = 0
    private(set) var position: DataFirstDifference.Position?
    private(set) var previousContext: DataDifferenceContext?
    private(set) var currentContext: DataDifferenceContext?
    private(set) var jumpInput = ""
    private(set) var jumpError: String?
    private(set) var revision = UUID()
    private var history = FoundDifferenceHistory<DataFirstDifference.Position>()
    private var frontierFinished = false
    private let previous: Data
    private let current: Data
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var cursor: DataFirstDifference?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?

    var canPrevious: Bool { (phase == .different || phase == .finished) && history.canPrevious }
    var canNext: Bool { (phase == .different || phase == .finished) && (history.canNext || !frontierFinished) }
    var historyNotice: String? { history.notice }
    var foundRange: String? { history.rangeLabel }
    var canJump: Bool { (phase == .different || phase == .finished) && position != nil }
    var copyDetails: String? {
        guard canJump, let position else { return nil }
        return CurrentDifferenceDetails.data(position, ordinal: differenceCount, previous: previousContext, current: currentContext)
    }
    func setJumpInput(_ value: String) {
        jumpInput = String(decoding: value.utf8.prefix(21), as: UTF8.self)
        jumpError = nil
    }
    func jumpToFound() {
        guard canJump else { return }
        guard let entry = history.select(input: jumpInput) else {
            jumpError = "Enter a found difference from " + (history.validRange ?? "the retained range") + "."
            return
        }
        generation = UUID(); work?.cancel(); work = nil
        restore(entry)
    }

    var message: String {
        switch phase {
        case .ready: "Compare original bytes in explicit portions; values remain base64."
        case .running: "Comparing this portion…"
        case .paused: position == nil ? "No difference yet. Continue Comparison to examine more." : "No further difference yet. Continue Comparison to examine more."
        case .equal: "No difference. Both original data values are equal."
        case .finished: "No further differences. The last difference remains available to reveal."
        case .failed: "Comparison could not complete. Use Find First Difference to restart."
        case .different:
            if let position {
                (differenceCount == 1 ? "First difference at byte \(position.byteOffset + 1)." : "Difference \(differenceCount) at byte \(position.byteOffset + 1).") +
                (position.previousByte == nil ? " Previous ends here; Current continues." :
                 position.currentByte == nil ? " Current ends here; Previous continues." : "")
            } else { "Difference found." }
        }
    }
    init(previous: Data, current: Data, runner: Runner? = nil) {
        self.previous = previous; self.current = current
        self.runner = runner ?? { cursor in
            let task = Task.detached(priority: .userInitiated) {
                var next = cursor; let result = try next.step(); return (next, result)
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }
    deinit { work?.cancel() }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil
        history = .init(); frontierFinished = false; jumpInput = ""; jumpError = nil
        cursor = nil; differenceCount = 0; position = nil; previousContext = nil; currentContext = nil; phase = .ready
    }
    @discardableResult
    func find() -> Task<Void, Never>? {
        cancel(); cursor = DataFirstDifference(previous: previous, current: current)
        return advance()
    }
    func previousFound() {
        guard canPrevious, let entry = history.previous() else { return }
        generation = UUID(); work?.cancel(); work = nil
        restore(entry)
    }
    @discardableResult
    func next() -> Task<Void, Never>? {
        guard canNext else { return nil }
        generation = UUID(); work?.cancel(); work = nil
        if let entry = history.next() {
            restore(entry)
            return Task {}
        }
        guard var cursor, cursor.movePastDifference() else { return nil }
        self.cursor = cursor; phase = .ready
        return advance()
    }
    private func restore(_ entry: FoundDifferenceHistory<DataFirstDifference.Position>.Entry) {
        previousContext = DataDifferenceContext(data: previous, byteOffset: entry.position.byteOffset)
        currentContext = DataDifferenceContext(data: current, byteOffset: entry.position.byteOffset)
        jumpInput = String(entry.ordinal); jumpError = nil
        differenceCount = entry.ordinal; position = entry.position; revision = UUID()
        phase = frontierFinished && history.isAtFrontier ? .finished : .different
    }
    func reveal() { if position != nil { revision = UUID() } }
    @discardableResult
    func advance() -> Task<Void, Never>? {
        guard phase == .ready || phase == .paused, let cursor else { return nil }
        let request = generation, runner = runner
        phase = .running
        let task = Task {
            do {
                let (next, step) = try await runner(cursor)
                guard !Task.isCancelled, generation == request else { return }
                self.cursor = next
                switch step {
                case .more: phase = .paused
                case .equal: frontierFinished = true; phase = position == nil ? .equal : .finished
                case .difference(let found): restore(history.append(found))
                }
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                phase = .failed
            }
        }
        work = task; return task
    }
}
