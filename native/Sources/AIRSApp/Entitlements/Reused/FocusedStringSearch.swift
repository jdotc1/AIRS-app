import Foundation
import Observation
import EntitlementDiffCore
import EntitlementDiffModel

@MainActor @Observable
final class FocusedStringSearch {
    enum Phase { case ready, running, paused, matched, end, invalid, failed }
    typealias Runner = @Sendable (StringValueSearch) async throws -> (StringValueSearch, StringValueSearch.Step)
    private(set) var input = ExactKeyInput()
    private(set) var phase: Phase = .ready
    private(set) var direction: StringValueSearch.Direction = .forward
    private(set) var match: StringValueSearch.Match?
    private(set) var matchRevision = UUID()
    private(set) var revealRevision = UUID()
    private let source: String
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var cursor: StringValueSearch?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    static let copyByteLimit = 16_384
    /// Literal UTF-8 matching guarantees these bounded query bytes equal the captured source match.
    func copyText(side: ComparisonSide) -> String? {
        guard canReveal, let match else { return nil }
        let bytes = Array(input.value.utf8.prefix(1025))
        guard !bytes.isEmpty, bytes.count <= 1024 else { return nil }
        let escaped = input.value.unicodeScalars.map { "\\u{" + String(format: "%04X", $0.value) + "}" }.joined()
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let text = "\(side.label) text match details\n" +
            "UTF-8 byte range: \(match.byteOffset + 1)–\(match.byteOffset + bytes.count) (1-based, inclusive)\n" +
            "Starting Unicode scalar position: \(match.scalarOffset + 1) (1-based)\n" +
            "Match length: \(bytes.count) UTF-8 bytes\n" +
            "Matched text (Unicode scalar escapes): \(escaped)\nUTF-8: \(hex)\n" +
            "Positions and bytes refer to original text, without normalization.\n"
        return text.utf8.count <= Self.copyByteLimit ? text : nil
    }
    var canAdvance: Bool { phase == .paused || phase == .matched }
    var canReveal: Bool { phase != .running && match != nil }
    /// Reveal the captured match without replacing the search cursor or manual navigation.
    @discardableResult func reveal() -> Bool {
        guard canReveal else { return false }
        revealRevision = UUID()
        return true
    }
    func canSearch(_ direction: StringValueSearch.Direction) -> Bool {
        guard let cursor else { return false }
        if direction != cursor.direction { return match != nil }
        return canAdvance
    }
    var matchByteRange: Range<Int>? {
        guard let match else { return nil }
        return match.byteOffset..<(match.byteOffset + input.value.utf8.count)
    }
    var message: String {
        switch phase {
        case .ready: "Literal UTF-8 · 1–1,024 query bytes."
        case .running: direction == .backward ? "Searching backward through this portion…" : "Searching this portion…"
        case .paused: direction == .backward ? "No previous match yet. Continue backward to examine more." : "No next match yet. Continue Search to examine more."
        case .matched:
            if let match { "Match begins at byte \(match.byteOffset + 1) · page \(match.pageIndex + 1)." }
            else { "Match found." }
        case .end: direction == .backward ? "Reached the beginning. No earlier match; search does not wrap." : "Reached the end. No further match; search does not wrap."
        case .invalid: "Enter literal text from 1 through 1,024 UTF-8 bytes."
        case .failed: "Search could not complete. Use Find to restart."
        }
    }
    init(source: String, runner: Runner? = nil) {
        self.source = source
        self.runner = runner ?? { cursor in
            let task = Task.detached(priority: .userInitiated) {
                var next = cursor
                let result = try next.step()
                return (next, result)
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }
    deinit { work?.cancel() }
    func setQuery(_ input: ExactKeyInput) {
        guard self.input != input else { return }
        self.input = input
        cancel()
    }
    func clear() {
        input = .init(value: ""); cancel()
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil
        cursor = nil; match = nil; phase = .ready; direction = .forward
    }
    @discardableResult
    func find() -> Task<Void, Never>? {
        cancel()
        do { cursor = try StringValueSearch(source: source, query: input.value) }
        catch { phase = .invalid; return nil }
        return advance()
    }
    @discardableResult
    func advance(direction requested: StringValueSearch.Direction? = nil) -> Task<Void, Never>? {
        if let requested, let current = cursor, requested != current.direction {
            guard match != nil else { return nil }
            do { cursor = try current.searching(requested) }
            catch { return nil }
            generation = UUID(); work?.cancel(); work = nil
            direction = requested
            phase = .matched
        }
        guard phase != .running, let cursor else { return nil }
        guard phase == .ready || canAdvance else { return nil }
        let request = generation, runner = runner
        phase = .running
        let task = Task {
            do {
                let (next, step) = try await runner(cursor)
                guard !Task.isCancelled, request == generation else { return }
                self.cursor = next
                switch step {
                case .match(let found):
                    match = found; matchRevision = UUID(); phase = .matched
                case .more: phase = .paused
                case .end: phase = .end
                }
            } catch {
                guard !Task.isCancelled, request == generation else { return }
                phase = .failed
            }
        }
        work = task
        return task
    }
}
