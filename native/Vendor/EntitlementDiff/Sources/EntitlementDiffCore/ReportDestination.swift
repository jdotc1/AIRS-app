import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ReportDestinationError: Error, Sendable, LocalizedError {
    case localFileRequired
    case insideInputBundle
    public var errorDescription: String? {
        switch self {
        case .localFileRequired: "Choose a local file destination for the report."
        case .insideInputBundle: "A report cannot be written inside either selected application. Choose a separate folder."
        }
    }
}

public enum ReportDestination {
    /// Prevent accidental mutation of input bundles. This is a preflight, not
    /// a race-proof filesystem guarantee against a concurrently hostile writer.
    public static func validate(_ destination: URL, excluding inputs: [URL]) throws {
        guard destination.isFileURL, destination.host == nil || destination.host == "" || destination.host == "localhost" else { throw ReportDestinationError.localFileRequired }
        // Resolving a nonexistent leaf can leave its symlinked parent unresolved.
        // Save panels choose an existing directory; resolve that directory first.
        // Foundation can preserve system aliases such as /tmp on macOS.
        // Resolve the existing directory at the filesystem boundary instead.
        guard let resolved = destination.deletingLastPathComponent().withUnsafeFileSystemRepresentation({ path in
            path.flatMap { realpath($0, nil) }
        }) else { throw ReportDestinationError.localFileRequired }
        defer { free(resolved) }
        let parent = URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
        guard let values = try? parent.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
            throw ReportDestinationError.localFileRequired
        }
        let candidateURL = parent.appendingPathComponent(destination.lastPathComponent)
            .resolvingSymlinksInPath().standardizedFileURL
        try validate(entryURL: parent.appendingPathComponent(destination.lastPathComponent),
                     resolvedTargetURL: candidateURL, excluding: inputs)
    }

    // Separate ancestry policy from path resolution for synthetic policy tests.
    static func validate(entryURL: URL, resolvedTargetURL: URL, excluding inputs: [URL]) throws {
        // File identity also catches aliases whose spelling differs on a
        // case-insensitive filesystem. Device + inode are compared together.
        let protected = inputs.compactMap { identity($0.resolvingSymlinksInPath()) }
        // Atomic replacement can mutate the entry independently of its resolved target.
        for candidateURL in [entryURL, resolvedTargetURL] {
            var ancestor = candidateURL
            while true {
                if let current = identity(ancestor), protected.contains(current) {
                    throw ReportDestinationError.insideInputBundle
                }
                guard ancestor.pathComponents.count > 1 else { break }
                ancestor.deleteLastPathComponent()
            }
            let candidate = candidateURL.pathComponents
            for input in inputs {
                let base = input.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                if candidate.count >= base.count && zip(base, candidate).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) {
                    throw ReportDestinationError.insideInputBundle
                }
            }
        }
    }

    private struct FileIdentity: Equatable { let device: UInt64; let inode: UInt64 }
    private static func identity(_ url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return .init(device: device.uint64Value, inode: inode.uint64Value)
    }

}
