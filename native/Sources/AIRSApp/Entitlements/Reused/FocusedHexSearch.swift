import Foundation
import Observation
import EntitlementDiffModel

// Preserve the focused-search module surface after sharing the exact matcher.
typealias HexByteCursor = EntitlementDiffModel.HexByteCursor

@MainActor @Observable
final class FocusedHexSearch {
    enum Phase { case ready, running, paused, matched, end, invalid, failed }
    typealias Runner = @Sendable (HexByteCursor) async throws -> (HexByteCursor, HexByteCursor.Step)
    private(set) var direction: HexByteCursor.Direction = .forward
    private(set) var query = ""
    private(set) var phase: Phase = .ready
    private(set) var matchOffset: Int?
    private(set) var revision = UUID()
    private(set) var context: String?
    private var matchDetails: String?
    static let copyByteLimit = 1024
    private let source: Data
    @ObservationIgnored private let runner: Runner
    @ObservationIgnored private var cursor: HexByteCursor?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    var canAdvance: Bool { phase == .paused || phase == .matched }
    var canReveal: Bool { phase != .running && matchOffset != nil }
    func copyText(side: ComparisonSide) -> String? {
        guard canReveal, let matchDetails else { return nil }
        let text = "\(side.label) hex match details\n" + matchDetails
        return text.utf8.count <= Self.copyByteLimit ? text : nil
    }
    /// Publish only a new reveal identity; retain the cursor, direction and captured context.
    @discardableResult func reveal() -> Bool {
        guard canReveal else { return false }
        revision = UUID()
        return true
    }
    func canSearch(_ requested: HexByteCursor.Direction) -> Bool {
        guard phase != .running, let cursor else { return false }
        return requested == cursor.direction ? canAdvance : matchOffset != nil
    }
    var message: String {
        switch phase {
        case .ready: "Hex pairs · 1–128 bytes · optional spaces."
        case .running: direction == .backward ? "Searching backward through this portion…" : "Searching this portion…"
        case .paused: direction == .backward ? "No previous match yet. Continue Backward to examine more." : "No next match yet. Continue Search to examine more."
        case .matched: "Match at byte \((matchOffset ?? 0) + 1) (1-based). Brackets mark matched bytes; context preview is bounded."
        case .end: direction == .backward ? "Reached the beginning. No earlier match; search does not wrap." : "Reached the end. No further match; search does not wrap."
        case .invalid: "Enter 1–128 hex byte pairs, optionally separated by spaces."
        case .failed: "Search could not complete. Use Find Hex to restart."
        }
    }
    init(source: Data, runner: Runner? = nil) {
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
    func setQuery(_ text: String) {
        let bounded = String(decoding: text.utf8.prefix(384), as: UTF8.self)
        guard query != bounded else { return }
        query = bounded; cancel()
    }
    func clear() {
        query = ""; cancel()
    }
    func cancel() {
        generation = UUID(); work?.cancel(); work = nil; cursor = nil
        matchOffset = nil; context = nil; matchDetails = nil; phase = .ready; direction = .forward
    }
    @discardableResult func find() -> Task<Void, Never>? {
        cancel()
        do { cursor = try HexByteCursor(source: source, query: query) }
        catch { phase = .invalid; return nil }
        return advance()
    }
    @discardableResult func advance(direction requested: HexByteCursor.Direction? = nil) -> Task<Void, Never>? {
        guard phase != .running else { return nil }
        if let requested, let current = cursor, requested != current.direction {
            do { cursor = try current.searching(requested) }
            catch { return nil }
            generation = UUID(); work?.cancel(); work = nil
            direction = requested; phase = .matched
        }
        guard phase == .ready || canAdvance, let cursor else { return nil }
        let request = generation, runner = runner
        phase = .running
        let task = Task {
            do {
                let (next, result) = try await runner(cursor)
                guard !Task.isCancelled, request == generation else { return }
                self.cursor = next
                switch result {
                case .more: phase = .paused
                case .end: phase = .end
                case .match(let offset):
                    matchOffset = offset; revision = UUID(); phase = .matched
                    let end = offset + next.pattern.count
                    let lower = max(0, offset - 8), upper = min(source.count, end + 8)
                    func hex(_ range: Range<Int>) -> String {
                        range.map { String(format: "%02X", source[source.startIndex + $0]) }.joined(separator: " ")
                    }
                    matchDetails = "Byte range: \(offset + 1)–\(end) (1-based, inclusive)\n" +
                        "Match length: \(next.pattern.count) bytes\nMatched bytes: " + hex(offset..<end) +
                        "\nContext before (up to 8 bytes): " + hex(lower..<offset) +
                        "\nContext after (up to 8 bytes): " + hex(end..<upper) + "\n"
                    let previewEnd = min(end, offset + 16)
                    context = "Bytes \(offset + 1)–\(end): " + hex(lower..<offset) + " [" + hex(offset..<previewEnd) +
                        (previewEnd < end ? " …" : "") + "] " + hex(end..<upper)
                }
            } catch {
                guard !Task.isCancelled, request == generation else { return }
                phase = .failed
            }
        }
        work = task; return task
    }
}
