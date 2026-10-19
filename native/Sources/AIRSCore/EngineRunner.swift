import Foundation
import Darwin

public enum EngineCommand: Sendable {
    case audit(input: URL)
    case diff(baseline: Data, current: Data)
    case handoff(report: Data, findingID: String)
    case symbols(report: Data, dsym: URL)
}

public struct EngineArtifact: Sendable {
    public let data: Data
    public let statusText: String
}

/// One child process at a time. Cancellation retains ownership until it terminates.
public actor EngineRunner {
    private var active: EngineInvocation?

    public init() {}

    public func run(_ command: EngineCommand, configuration: EngineConfiguration) async throws -> EngineArtifact {
        guard active == nil else { throw EngineError.busy }
        try Task.checkCancellation()
        let invocation = try EngineInvocation(command: command, configuration: configuration)
        active = invocation
        defer {
            active = nil
            invocation.cleanup()
        }
        let artifact: EngineArtifact = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.start(continuation)
            }
        } onCancel: {
            invocation.cancel()
        }
        try Task.checkCancellation()
        return artifact
    }

    public func cancel() {
        active?.cancel()
    }
}

/// The lock protects launch/cancel/completion races between Foundation callbacks.
private final class EngineInvocation: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private let workDirectory: URL
    private let outputURL: URL
    private let stdoutURL: URL
    private let stderrURL: URL
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private var continuation: CheckedContinuation<EngineArtifact, Error>?
    private var started = false
    private var finished = false
    private var cancellationRequested = false

    init(command: EngineCommand, configuration: EngineConfiguration) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIRS-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("output.json")
        let standardOutput = directory.appendingPathComponent("stdout.log")
        let standardError = directory.appendingPathComponent("stderr.log")
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let openedStdout: FileHandle
        let openedStderr: FileHandle
        do {
            guard fileManager.createFile(atPath: standardOutput.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]),
                  fileManager.createFile(atPath: standardError.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw EngineError.launchFailed("Could not create private output files.")
            }
            openedStdout = try FileHandle(forWritingTo: standardOutput)
            do {
                openedStderr = try FileHandle(forWritingTo: standardError)
            } catch {
                try? openedStdout.close()
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        workDirectory = directory
        outputURL = output
        stdoutURL = standardOutput
        stderrURL = standardError
        stdoutHandle = openedStdout
        stderrHandle = openedStderr

        do {
            let arguments: [String]
            switch command {
            case .audit(let input):
                arguments = ["audit", "--format", "json", "--output", outputURL.path,
                             "--", input.path]
            case .diff(let baseline, let current):
                let baselineURL = workDirectory.appendingPathComponent("baseline.json")
                let currentURL = workDirectory.appendingPathComponent("current.json")
                try baseline.write(to: baselineURL, options: .atomic)
                try current.write(to: currentURL, options: .atomic)
                arguments = ["diff", "--baseline", baselineURL.path,
                             "--current", currentURL.path, "--output", outputURL.path]
            case .symbols(let report, let dsym):
                let reportURL = workDirectory.appendingPathComponent("report.json")
                try report.write(to: reportURL, options: .atomic)
                arguments = ["symbols", "--report", reportURL.path, "--dsym", dsym.path,
                             "--output", outputURL.path]
            case .handoff(let report, let findingID):
                let reportURL = workDirectory.appendingPathComponent("report.json")
                try report.write(to: reportURL, options: .atomic)
                arguments = ["handoff", "--report", reportURL.path,
                             "--finding-id", findingID, "--output", outputURL.path]
            }
            process.executableURL = configuration.pythonExecutable
            process.arguments = ["-I", "-B", "-S", configuration.bootstrap.path] + arguments
            process.currentDirectoryURL = workDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            process.environment = EngineConfiguration.isolatedEnvironment(ProcessInfo.processInfo.environment)
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? fileManager.removeItem(at: workDirectory)
            throw error
        }
    }

    func start(_ continuation: CheckedContinuation<EngineArtifact, Error>) {
        lock.lock()
        self.continuation = continuation
        if cancellationRequested {
            lock.unlock()
            finish(.failure(CancellationError()))
            return
        }
        process.terminationHandler = { [weak self] _ in self?.didTerminate() }
        do {
            try process.run()
            started = true
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(EngineError.launchFailed(error.localizedDescription)))
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldTerminate = started && !finished
        lock.unlock()
        guard shouldTerminate, process.isRunning else { return }
        let ownedPID = process.processIdentifier
        process.terminate()
        // A stuck owned child must not prevent the next analysis indefinitely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            let stillActive = started && !finished && cancellationRequested
            lock.unlock()
            if stillActive, process.isRunning, process.processIdentifier == ownedPID {
                _ = Darwin.kill(ownedPID, SIGKILL)
            }
        }
    }

    private func didTerminate() {
        lock.lock()
        let wasCancelled = cancellationRequested
        lock.unlock()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        if wasCancelled {
            finish(.failure(CancellationError()))
            return
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let diagnostic = Self.readTail(stderrURL)
            finish(.failure(EngineError.failed(status: process.terminationStatus,
                                               diagnostic: diagnostic)))
            return
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            finish(.failure(EngineError.missingOutput))
            return
        }
        do {
            let data = try ReportFiles.readBounded(outputURL)
            finish(.success(EngineArtifact(data: data, statusText: Self.readTail(stdoutURL))))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<EngineArtifact, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cleanup() {
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    private static func readTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            let limit: UInt64 = 16 * 1024
            try handle.seek(toOffset: length > limit ? length - limit : 0)
            let data = try handle.read(upToCount: Int(limit)) ?? Data()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return "" }
    }
}
