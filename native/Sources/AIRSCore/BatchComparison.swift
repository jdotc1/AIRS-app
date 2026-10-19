import Foundation

public struct BatchImagePair: Codable, Equatable, Sendable {
    public let baselineID: UUID
    public let currentID: UUID
    public init(baselineID: UUID, currentID: UUID) { self.baselineID = baselineID; self.currentID = currentID }
}

public struct BatchComparisonPlan: Identifiable, Sendable {
    public let id = UUID()
    public let baseline: ImageBatchSnapshot
    public let current: ImageBatchSnapshot

    public init(baseline: ImageBatchSnapshot, current: ImageBatchSnapshot) throws {
        guard baseline.id != current.id, !baseline.items.isEmpty, !current.items.isEmpty,
              baseline.items.count <= 16, current.items.count <= 16,
              Set(baseline.items.map(\.id)).count == baseline.items.count,
              Set(current.items.map(\.id)).count == current.items.count else {
            throw ReportError.invalidContents("Choose two different bounded batches with unique image rows.")
        }
        self.baseline = baseline; self.current = current
    }

    // MacScope FunctionVersionMatcher: accept a key only when unique on BOTH sides.
    // Suggestions are never submitted without the user's explicit confirmation.
    public var suggestions: [BatchImagePair] {
        current.items.compactMap { item in
            guard item.status == .completed, let image = item.image else { return nil }
            let old = baseline.items.filter { $0.status == .completed && Self.sameSlice($0.image, image) }
            let new = current.items.filter { $0.status == .completed && Self.sameSlice($0.image, image) }
            guard old.count == 1, new.count == 1, let first = old.first else { return nil }
            return BatchImagePair(baselineID: first.id, currentID: item.id)
        }
    }

    public func validate(_ pairs: [BatchImagePair]) throws {
        // Adapted from MacScope validatedPins: existence and one-to-one ownership.
        guard pairs.count <= 16, Set(pairs.map(\.baselineID)).count == pairs.count,
              Set(pairs.map(\.currentID)).count == pairs.count,
              pairs.allSatisfy({ pair in baseline.items.contains { $0.id == pair.baselineID }
                && current.items.contains { $0.id == pair.currentID } }) else {
            throw ReportError.invalidContents("Each image can be paired once, and must belong to its selected batch.")
        }
    }

    private static func sameSlice(_ lhs: ImageInfo?, _ rhs: ImageInfo) -> Bool {
        guard let lhs else { return false }
        return lhs.sliceSHA256 == rhs.sliceSHA256 && lhs.architecture == rhs.architecture
            && lhs.cpuSubtype == rhs.cpuSubtype && lhs.uuid == rhs.uuid
    }
}

public struct BatchComparisonRow: Identifiable, Sendable {
    public let id: String
    public let baseline: ImageBatchItem?
    public let current: ImageBatchItem?
    public var state: String
    public var message: String
    public var comparisonData: Data?
    public var comparison: ComparisonReport?
    public var configurationChanged = false
}

public struct BatchComparisonResult: Sendable {
    public let plan: BatchComparisonPlan
    public var rows: [BatchComparisonRow]
    public var settled: Bool
    public var cancelled: Bool

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        func reference(_ item: ImageBatchItem?) throws -> Any {
            guard let item else { return NSNull() }
            var value: [String: Any] = ["item_id": item.id.uuidString, "input": item.input.path,
                "analysis_outcome": item.status.rawValue, "analysis_message": item.message,
                "report_model": item.model ?? NSNull() as Any]
            value["retained_report_id"] = item.retainedReportID?.uuidString ?? NSNull() as Any
            value["bundle_provenance"] = try item.bundleImage.map { try object($0) } ?? NSNull()
            value["image"] = try item.image.map { try object($0) } ?? NSNull()
            return value
        }
        let entries: [[String: Any]] = try rows.map { row in
            var entry: [String: Any] = ["id": row.id, "baseline": try reference(row.baseline),
                "current": try reference(row.current), "state": row.state, "message": row.message,
                "analysis_configuration_changed": row.configurationChanged]
            if let data = row.comparisonData { entry["comparison"] = try JSONSerialization.jsonObject(with: data) }
            return entry
        }
        let value: [String: Any] = ["schema_version": 1, "report_kind": "airs.batch_comparison",
            "baseline_batch_id": plan.baseline.id.uuidString, "current_batch_id": plan.current.id.uuidString,
            "baseline_checkpoint_revision": plan.baseline.checkpointRevision?.uuidString ?? NSNull() as Any,
            "current_checkpoint_revision": plan.current.checkpointRevision?.uuidString ?? NSNull() as Any,
            "settled": settled, "cancelled": cancelled, "pairing_policy": "explicit_one_to_one",
            "baseline_selected_count": plan.baseline.items.count, "current_selected_count": plan.current.items.count,
            "rows": entries, "limitations": ["Image pairings were explicitly confirmed; cross-build function matches remain candidates.",
                "Unpaired, failed and unfinished images are not regressions or fixes.",
                "Raw audit reports remain unchanged in their original storage; references are local library IDs.",
                "No image was reanalyzed. Every conclusion retains its source report scope."]]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        guard data.count <= ReportFiles.maximumBytes else { throw ReportError.tooLarge(ReportFiles.maximumBytes) }
        return data
    }
}

public actor BatchComparisonRunner {
    public init() {}
    public func run(plan: BatchComparisonPlan, pairs: [BatchImagePair],
                    load: @Sendable (UUID) async throws -> RetainedReport,
                    compare: @Sendable (Data, Data) async throws -> Data,
                    progress: @Sendable (BatchComparisonResult) async -> Void = { _ in }) async throws -> BatchComparisonResult {
        try plan.validate(pairs)
        var rows = plan.current.items.map { item -> BatchComparisonRow in
            let pair = pairs.first { $0.currentID == item.id }
            let old = pair.flatMap { pair in plan.baseline.items.first { $0.id == pair.baselineID } }
            return BatchComparisonRow(id: "current:\(item.id)", baseline: old, current: item,
                state: old == nil ? "unpaired_current" : "pending", message: old == nil ? "No baseline image explicitly paired." : "Waiting for comparison.")
        }
        rows += plan.baseline.items.filter { old in !pairs.contains { $0.baselineID == old.id } }.map {
            BatchComparisonRow(id: "baseline:\($0.id)", baseline: $0, current: nil,
                state: "unpaired_baseline", message: "No current image explicitly paired.")
        }
        var result = BatchComparisonResult(plan: plan, rows: rows, settled: false, cancelled: false)
        await progress(result)
        var remaining = ReportFiles.maximumBytes / 2 // leaves bounded space for the export envelope
        for index in result.rows.indices where result.rows[index].state == "pending" {
            if Task.isCancelled { result.cancelled = true; break }
            do {
                guard let old = result.rows[index].baseline, let new = result.rows[index].current,
                      old.status == .completed, new.status == .completed,
                      let oldID = old.retainedReportID, let newID = new.retainedReportID else {
                    throw ReportError.invalidContents("Both images need completed reports retained in Report Library. Original outcomes remain visible.")
                }
                let baseline = try await load(oldID)
                let current = try await load(newID)
                try Self.validate(baseline, item: old); try Self.validate(current, item: new)
                let oldConfig = try Self.configuration(baseline.data), newConfig = try Self.configuration(current.data)
                result.rows[index].configurationChanged = oldConfig == nil || newConfig == nil || oldConfig != newConfig
                guard baseline.report.generator.analysisModelVersion == current.report.generator.analysisModelVersion,
                      baseline.report.image.architecture == current.report.image.architecture,
                      baseline.report.image.cpuSubtype == current.report.image.cpuSubtype else {
                    result.rows[index].state = "incompatible"
                    result.rows[index].message = "Analysis model, architecture or CPU subtype differs; no verdict comparison performed."
                    await progress(result); continue
                }
                try Task.checkCancellation()
                let data = try await compare(baseline.data, current.data)
                try Task.checkCancellation()
                guard data.count <= remaining else { throw ReportError.invalidContents("Batch comparison output budget exhausted.") }
                let decoded = try ComparisonReport.decode(data)
                guard Self.matches(decoded.comparison.baselineImage, baseline.report.image),
                      Self.matches(decoded.comparison.currentImage, current.report.image) else {
                    throw ReportError.invalidContents("Comparison returned different image identities.")
                }
                remaining -= data.count
                result.rows[index].comparisonData = data; result.rows[index].comparison = decoded
                result.rows[index].state = "compared"
                result.rows[index].message = result.rows[index].configurationChanged
                    ? "Configuration differs or is missing; scope and budget changes require review."
                    : "Compared using the existing report engine. Function matching limitations remain."
            } catch is CancellationError { result.cancelled = true; break }
            catch {
                result.rows[index].state = "unavailable"
                result.rows[index].message = error.localizedDescription
            }
            await progress(result)
        }
        for index in result.rows.indices where result.rows[index].state == "pending" {
            result.rows[index].state = "not_compared"
            result.rows[index].message = "Cancelled before comparison completed."
        }
        result.cancelled = result.cancelled || Task.isCancelled
        result.settled = true
        await progress(result)
        return result
    }

    private static func validate(_ retained: RetainedReport, item: ImageBatchItem) throws {
        guard let image = item.image, item.model == retained.report.generator.analysisModelVersion,
              try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? NSDictionary
                == JSONSerialization.jsonObject(with: JSONEncoder().encode(retained.report.image)) as? NSDictionary else {
            throw ReportError.invalidContents("Retained report no longer matches the saved batch image/model.")
        }
    }

    private static func configuration(_ data: Data) throws -> NSDictionary? {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["analysis_config"] as? NSDictionary
    }
    private static func matches(_ actual: ComparisonImage, _ expected: ImageInfo) -> Bool {
        actual.sliceSHA256 == expected.sliceSHA256 && actual.architecture == expected.architecture && actual.uuid == expected.uuid
    }
}
