import Foundation

// Adapted from MacScope ReconstructionBatchScheduler's bounded task budget,
// terminal outcomes and execution-generation discipline. AIRS uses one child.
public enum ImageBatchStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, notStarted, duplicate

    public var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Analyzing"
        case .completed: return "Analysis completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .notStarted: return "Not started"
        case .duplicate: return "Duplicate selection skipped"
        }
    }
}

public struct ImageBatchItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let input: URL
    public var status: ImageBatchStatus
    public var message: String
    public var retainedReportID: UUID?
    public var image: ImageInfo?
    public var summary: ReportSummary?
    public var model: String?
    // At most one valid result may be held here if its library commit failed.
    // Stop the queue so completed bytes are never dropped to make room.
    public var unretainedData: Data?
    public var bundleImage: BundleImageProvenance?
    public var inputIdentity: BatchInputIdentity?
    public var attempts: [ImageBatchAttempt] = []
    public var reportByteCount: Int = 0
    public var reusedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, input, status, message, retainedReportID, image, summary, model
        case inputIdentity, attempts, reportByteCount, bundleImage, reusedAt
    }
}

public struct ImageBatchSnapshot: Codable, Sendable {
    public let id: UUID
    public var items: [ImageBatchItem]
    public var settled: Bool
    public var executionID = UUID()
    public var previousExecutionID: UUID?
    public var checkpointRevision: UUID?
    public var context: BatchExecutionContext?
    public var persistenceError: String?
    public var hasUnretainedReports: Bool { items.contains { $0.unretainedData != nil } }
}

public actor ImageBatchRunner {
    public static let maximumImages = 16
    public static let maximumReportBytes = ReportFiles.maximumBytes
    public static let maximumTotalBytes = 128 * 1_048_576
    private var active = false
    private let maximumImages: Int
    private let maximumReportBytes: Int
    private let maximumTotalBytes: Int

    public init(maximumImages: Int = ImageBatchRunner.maximumImages,
                maximumReportBytes: Int = ImageBatchRunner.maximumReportBytes,
                maximumTotalBytes: Int = ImageBatchRunner.maximumTotalBytes) {
        self.maximumImages = maximumImages
        self.maximumReportBytes = maximumReportBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public func run(
        inputs: [URL], id: UUID = UUID(),
        resuming: ImageBatchSnapshot? = nil,
        context: BatchExecutionContext? = nil,
        bundleImages: [URL: BundleImageProvenance] = [:],
        audit: @Sendable (URL) async throws -> Data,
        reuse: @Sendable (URL) async throws -> AnalysisReuseHit? = { _ in nil },
        retain: @Sendable (Data, URL) async throws -> UUID,
        checkpoint: @Sendable (ImageBatchSnapshot) async throws -> UUID? = { _ in nil },
        progress: @Sendable (ImageBatchSnapshot) async -> Void = { _ in }
    ) async throws -> ImageBatchSnapshot {
        guard !active else { throw EngineError.busy }
        guard !inputs.isEmpty, inputs.count <= maximumImages,
              maximumReportBytes > 0, maximumTotalBytes >= maximumReportBytes else {
            throw ReportError.invalidContents("Select between 1 and \(maximumImages) images for a bounded batch.")
        }
        active = true
        defer { active = false }
        var seen = Set<String>()
        var snapshot = ImageBatchSnapshot(id: id, items: inputs.map { input in
            let duplicate = !seen.insert(input.resolvingSymlinksInPath().standardizedFileURL.path).inserted
            return ImageBatchItem(id: UUID(), input: input,
                status: duplicate ? .duplicate : .queued,
                message: duplicate ? "Same resolved path was already selected; no second audit." : "Waiting for its turn.",
                bundleImage: bundleImages[input])
        }, settled: false)
        if let previous = resuming {
            guard previous.context == context, !previous.hasUnretainedReports,
                  previous.persistenceError == nil, previous.items.count == inputs.count,
                  !previous.items.contains(where: { $0.status == .running }),
                  previous.items.map(\.input) == inputs,
                  previous.items.allSatisfy({ $0.attempts.count < 16 }) else {
                throw ReportError.invalidContents("Resume context changed, report needs saving, or attempt limit reached. Start a new explicit batch instead.")
            }
            snapshot = previous
            snapshot.settled = false
            for index in snapshot.items.indices {
                let status = snapshot.items[index].status
                guard [.queued, .cancelled, .notStarted].contains(status) else { continue }
                snapshot.items[index].attempts.append(ImageBatchAttempt(status: status,
                    message: snapshot.items[index].message, date: Date()))
                snapshot.items[index].status = .queued
                snapshot.items[index].message = "Explicitly resumed; previous outcome preserved below."
            }
        } else {
            for index in snapshot.items.indices where snapshot.items[index].status == .queued {
                do {
                    if let provenance = snapshot.items[index].bundleImage {
                        try BundleDiscovery.validate(provenance, input: snapshot.items[index].input)
                        snapshot.items[index].inputIdentity = BatchInputIdentity(files: [provenance.fileIdentity])
                    } else { snapshot.items[index].inputIdentity = try BatchInputIdentity.capture(snapshot.items[index].input) }
                }
                catch {
                    snapshot.items[index].status = .failed
                    snapshot.items[index].message = error.localizedDescription
                }
            }
        }
        snapshot.executionID = id
        snapshot.previousExecutionID = resuming?.executionID
        snapshot.context = context
        func publish(_ value: ImageBatchSnapshot) async -> (String?, UUID?) {
            await progress(value)
            do { return (nil, try await checkpoint(value)) }
            catch { return ("Batch history could not be saved: \(error.localizedDescription)", nil) }
        }
        let initial = await publish(snapshot)
        snapshot.persistenceError = initial.0
        snapshot.checkpointRevision = initial.1 ?? snapshot.checkpointRevision
        var totalBytes = snapshot.items.reduce(0) { $0 + $1.reportByteCount }
        var stopReason: String?
        if snapshot.persistenceError != nil { stopReason = "Not started because the batch checkpoint could not be saved." }
        for index in snapshot.items.indices where snapshot.items[index].status == .queued {
            if Task.isCancelled { stopReason = "Batch cancelled before this image started." }
            // Reserve the full per-image allowance before launching another job.
            if stopReason == nil, totalBytes > maximumTotalBytes - maximumReportBytes {
                stopReason = "Batch report-byte budget reached; completed reports are preserved."
            }
            if let stopReason {
                snapshot.items[index].status = .notStarted
                snapshot.items[index].message = stopReason
                continue
            }
            let input = snapshot.items[index].input
            snapshot.items[index].status = .running
            snapshot.items[index].message = "One owned analysis; input is read as data."
            let starting = await publish(snapshot)
            snapshot.checkpointRevision = starting.1 ?? snapshot.checkpointRevision
            if let error = starting.0 {
                snapshot.persistenceError = error
                snapshot.items[index].status = .notStarted
                snapshot.items[index].message = error
                stopReason = "Batch checkpoint failed before launching this image."
                continue
            }
            do {
                try Task.checkCancellation()
                if let provenance = snapshot.items[index].bundleImage { try BundleDiscovery.validate(provenance, input: input) }
                guard let expected = snapshot.items[index].inputIdentity,
                      try BatchInputIdentity.capture(input) == expected else {
                    throw ReportError.invalidContents("Selected input changed since queue admission. It was not analyzed; select it in a new batch.")
                }
                let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                guard values.isRegularFile == true || (values.isDirectory == true && input.pathExtension.lowercased() == "app") else {
                    throw ReportError.invalidContents("Choose a regular image file or an .app bundle; directories are not recursively scanned.")
                }
                let hit = try await reuse(input)
                let data: Data
                if let hit { data = hit.data } else { data = try await audit(input) }
                try Task.checkCancellation()
                guard data.count <= maximumReportBytes else { throw ReportError.tooLarge(maximumReportBytes) }
                let report = try AuditReport.decode(data)
                totalBytes += data.count
                snapshot.items[index].image = report.image
                snapshot.items[index].summary = report.summary
                snapshot.items[index].model = report.generator.analysisModelVersion
                snapshot.items[index].reportByteCount = data.count
                snapshot.items[index].status = .completed
                snapshot.items[index].unretainedData = data
                snapshot.items[index].message = "Completed report awaiting durable retention."
                let completed = await publish(snapshot)
                snapshot.checkpointRevision = completed.1 ?? snapshot.checkpointRevision
                if let error = completed.0 {
                    snapshot.persistenceError = error
                    stopReason = error
                    continue
                }
                // From this point the report is completed. A cancellation during
                // its atomic library commit stops the next image, not this result.
                do {
                    let retainedID: UUID
                    if let hit {
                        retainedID = hit.retainedID
                        snapshot.items[index].reusedAt = hit.generatedAt
                    } else { retainedID = try await retain(data, input) }
                    snapshot.items[index].retainedReportID = retainedID
                    snapshot.items[index].unretainedData = nil
                    snapshot.items[index].message = hit.map { "Reused saved analysis from \($0.generatedAt.formatted()). Original report unchanged; no analysis child started." } ?? "Original report retained in library."
                } catch {
                    snapshot.items[index].unretainedData = data
                    snapshot.items[index].message = "Completed, but not retained: \(error.localizedDescription) The session copy is preserved; queue stopped."
                    stopReason = "Not started because a completed report needs to be saved."
                }
                snapshot.items[index].status = .completed
            } catch {
                if error is CancellationError || Task.isCancelled {
                    snapshot.items[index].status = .cancelled
                    snapshot.items[index].message = "Owned analysis settled after cancellation; no completed report admitted."
                    stopReason = "Batch cancelled before this image started."
                } else {
                    snapshot.items[index].status = .failed
                    snapshot.items[index].message = error.localizedDescription
                }
            }
            let outcome = await publish(snapshot)
            snapshot.checkpointRevision = outcome.1 ?? snapshot.checkpointRevision
            if let error = outcome.0 {
                snapshot.persistenceError = error
                stopReason = error
            }
        }
        snapshot.settled = true
        let final = await publish(snapshot)
        snapshot.persistenceError = final.0
        snapshot.checkpointRevision = final.1 ?? snapshot.checkpointRevision
        await progress(snapshot)
        return snapshot
    }
}
