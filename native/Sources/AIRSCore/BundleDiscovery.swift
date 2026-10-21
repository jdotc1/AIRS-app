import Darwin
import Foundation

public struct BundleImageProvenance: Codable, Equatable, Sendable {
    public let bundle: URL
    public let relativePath: String
    public let inventoryID: UUID
    public let rootDevice: UInt64
    public let rootInode: UInt64
    public let fileIdentity: ResumeFileIdentity
    public var inventoryPartial = false
    public var inventoryCancelled = false
}

public struct BundleDiscoveryEntry: Identifiable, Sendable {
    public let id = UUID() // allocated once in the captured inventory, never during view rendering
    public let relativePath: String
    public let state: String
    public let message: String
    public var provenance: BundleImageProvenance?
    public var selectable: Bool { provenance != nil }
}

/// Captured declaration bytes do not confer an executable or code-unit capability.
public struct BundleResourceDeclarations: Sendable {
    public let info: Data
    public let privacy: Data?
    public let privacyIssue: String?
}

public struct BundleDiscoveryResult: Identifiable, Sendable {
    public let id: UUID
    public let bundle: URL
    public var entries: [BundleDiscoveryEntry]
    public var partial: Bool
    public var cancelled: Bool
    public var visited: Int
    public var headerBytes: Int
    public var searchedLocations: [String] = []
    public var resourceDeclarations: BundleResourceDeclarations? = nil
}

/// Narrow adaptation of MacScope ReconstructionContainerManifestBuilder's
/// descriptor-relative, no-follow traversal, and ArtifactClassifier's magic-byte
/// classification. No content attachments, hashes or reconstruction dependencies.
public struct BundleDiscovery: Sendable {
    public struct Limits: Sendable {
        public let entries: Int
        public let depth: Int
        public let candidates: Int
        public let headerBytes: Int
        public init(entries: Int = 4096, depth: Int = 12, candidates: Int = 128, headerBytes: Int = 1_048_576) {
            self.entries = entries; self.depth = depth; self.candidates = candidates; self.headerBytes = headerBytes
        }
    }
    public static let codeLocations = ["MacOS", "Frameworks", "PlugIns", "XPCServices", "Helpers", "Library/LoginItems"]
    private let limits: Limits
    public init(limits: Limits = Limits()) { self.limits = limits }

    public func discover(_ selected: URL) throws -> BundleDiscoveryResult {
        guard selected.isFileURL, selected.pathExtension.lowercased() == "app",
              limits.entries > 0, limits.entries <= 4096, limits.depth > 0, limits.depth <= 12,
              limits.candidates > 0, limits.candidates <= 128, limits.headerBytes >= 4096,
              limits.headerBytes <= 1_048_576 else {
            throw ReportError.invalidContents("Choose one .app directory with bounded discovery limits.")
        }
        let root = selected.standardizedFileURL
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("App root is unavailable or a symbolic link.") }
        defer { Darwin.close(fd) }
        let rootStat = try metadata(fd)
        // Resolve parent aliases only after opening and binding the selected root.
        let bundle = root.resolvingSymlinksInPath()
        let opened = Darwin.open(bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { throw failure("App root moved during discovery.") }
        defer { Darwin.close(opened) }
        let canonical = try metadata(opened)
        guard canonical.st_dev == rootStat.st_dev, canonical.st_ino == rootStat.st_ino else { throw failure("App root changed during discovery.") }
        let contents = try openChild(fd, name: "Contents", directory: true)
        defer { Darwin.close(contents) }
        let plistFD = try openChild(contents, name: "Info.plist", directory: false)
        defer { Darwin.close(plistFD) }
        let plistStat = try metadata(plistFD)
        guard (plistStat.st_mode & S_IFMT) == S_IFREG, plistStat.st_size > 0, plistStat.st_size <= 65_536 else { throw failure("Info.plist must be a bounded regular file.") }
        let plist = try prefix(plistFD, count: Int(plistStat.st_size))
        guard let object = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { throw failure("App Info.plist is not a dictionary.") }
        let executable: String?
        if let declared = object["CFBundleExecutable"] {
            guard let name = declared as? String, safe(name), name.utf8.count <= 255 else { throw failure("App Info.plist has no safe principal executable name.") }
            executable = name
        } else { executable = nil }
        var result = BundleDiscoveryResult(id: UUID(), bundle: bundle, entries: [], partial: false, cancelled: false, visited: 0, headerBytes: 0)
        var seen = Set<String>()
        var candidates = 0
        var stopped = false
        func row(_ path: String, _ state: String, _ message: String, _ provenance: BundleImageProvenance? = nil) {
            result.entries.append(BundleDiscoveryEntry(relativePath: path, state: state, message: message, provenance: provenance))
        }
        func walk(_ directory: Int32, _ relative: String, _ depth: Int) throws {
            if Task.isCancelled { result.cancelled = true; result.partial = true; stopped = true; return }
            guard !stopped else { return }
            guard depth <= limits.depth else { result.partial = true; row(relative, "depth_limit", "Directory not traversed: depth limit."); return }
            let before = try metadata(directory)
            let duplicate = Darwin.dup(directory)
            guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
                if duplicate >= 0 { Darwin.close(duplicate) }; throw failure("Cannot enumerate directory.")
            }
            defer { Darwin.closedir(stream) }
            var names: [String] = []
            while true {
                if Task.isCancelled { result.cancelled = true; result.partial = true; stopped = true; break }
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    if errno != 0 { result.partial = true; row(relative + "/[enumeration]", "unreadable", "Directory enumeration failed.") }
                    break
                }
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { String(validatingCString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard result.visited < limits.entries else { result.partial = true; stopped = true; row(relative + "/[limit]", "entry_limit", "Entry budget reached; inventory is partial."); break }
                // Charge every captured directory entry, including invalid names and
                // siblings not yet processed when a recursive branch reaches a limit.
                result.visited += 1
                guard let name else { result.partial = true; row(relative + "/[non-UTF8]", "invalid_name", "Non-UTF8 entry skipped; inventory is partial."); continue }
                names.append(name)
            }
            // A directory too large to capture deterministically is not partly guessed.
            guard !stopped else { return }
            for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                if Task.isCancelled { result.cancelled = true; result.partial = true; stopped = true; break }
                if stopped { break }
                let path = relative + "/" + name
                guard safe(name), path.utf8.count <= 4096 else { result.partial = true; row(path, "path_limit", "Unsafe or oversized path skipped."); continue }
                var info = stat()
                guard name.withCString({ Darwin.fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { result.partial = true; row(path, "unreadable", "Entry metadata unavailable."); continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: row(path, "skipped_link", "Symbolic link not followed; physical framework versions may appear separately.")
                case S_IFDIR:
                    do { let child = try openChild(directory, name: name, directory: true); defer { Darwin.close(child) }; try walk(child, path, depth + 1) }
                    catch { result.partial = true; row(path, "unreadable", error.localizedDescription) }
                case S_IFREG:
                    do {
                        let file = try openChild(directory, name: name, directory: false); defer { Darwin.close(file) }
                        let before = try metadata(file)
                        guard same(info, before), (before.st_mode & S_IFMT) == S_IFREG else { throw failure("Entry changed before header read.") }
                        let count = Int(min(before.st_size, 4096))
                        guard count >= 0, count <= limits.headerBytes - result.headerBytes else { result.partial = true; stopped = true; row(path, "header_limit", "Header-read budget reached."); break }
                        let data = try prefix(file, count: count); result.headerBytes += data.count
                        guard same(before, try metadata(file)) else { throw failure("File changed during header read.") }
                        let classification = Self.classify(data, size: UInt64(before.st_size))
                        guard classification.0 else { row(path, classification.1, classification.2); continue }
                        let key = "\(before.st_dev):\(before.st_ino)"
                        guard seen.insert(key).inserted else { row(path, "duplicate_file", "Same physical file already discovered; not selected twice."); continue }
                        guard candidates < limits.candidates else { result.partial = true; stopped = true; row(path, "candidate_limit", "Candidate limit reached."); break }
                        candidates += 1
                        let identity = ResumeFileIdentity(path: bundle.appendingPathComponent(path).path,
                            device: UInt64(UInt32(bitPattern: before.st_dev)), inode: before.st_ino, size: before.st_size,
                            modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanos: Int64(before.st_mtimespec.tv_nsec),
                            changedSeconds: Int64(before.st_ctimespec.tv_sec), changedNanos: Int64(before.st_ctimespec.tv_nsec))
                        row(path, "candidate", classification.2 + (executable.map { path == "Contents/MacOS/" + $0 } == true ? " · Principal executable" : ""),
                            BundleImageProvenance(bundle: bundle, relativePath: path, inventoryID: result.id,
                                rootDevice: UInt64(UInt32(bitPattern: rootStat.st_dev)), rootInode: rootStat.st_ino, fileIdentity: identity))
                    } catch { result.partial = true; row(path, "unreadable", error.localizedDescription) }
                default: row(path, "skipped_special", "Special file not opened.")
                }
            }
            if !same(before, try metadata(directory)) { result.partial = true; row(relative + "/[changed]", "changed", "Directory changed during discovery; review a partial inventory.") }
        }
        for location in Self.codeLocations {
            if stopped { break }
            let relative = "Contents/" + location
            result.searchedLocations.append(relative)
            do {
                let directory = try openRelative(fd, components: relative.split(separator: "/").map(String.init), directory: true)
                defer { Darwin.close(directory) }
                try walk(directory, relative, 1)
            } catch {
                // Optional absent code locations are ordinary; other failures stay visible.
                if (error as NSError).code != Int(ENOENT) { result.partial = true; row(relative, "unreadable_or_link", error.localizedDescription) }
            }
        }
        if Task.isCancelled { result.cancelled = true; result.partial = true }
        if let executable {
            if !result.entries.contains(where: { $0.relativePath == "Contents/MacOS/" + executable && $0.selectable }) {
                result.partial = true; row("[principal]", "principal_unavailable", "Declared principal executable was not captured in the bounded inventory.")
            }
        } else {
            result.partial = true
            row("[principal]", "principal_unresolved", "CFBundleExecutable is absent; principal executable unresolved. Declarations do not authorize image selection or entitlement reads.")
            var privacy: Data?, privacyIssue: String?
            if Task.isCancelled { result.cancelled = true; privacyIssue = "Privacy declaration capture cancelled." }
            else {
                do {
                    let file = try openRelative(fd, components: ["Contents", "Resources", "PrivacyInfo.xcprivacy"], directory: false)
                    defer { Darwin.close(file) }
                    let before = try metadata(file)
                    guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size > 0, before.st_size <= 65_536 else { throw failure("Privacy metadata must be a bounded regular file.") }
                    privacy = try prefix(file, count: Int(before.st_size))
                    guard same(before, try metadata(file)) else { throw failure("Privacy metadata changed during capture.") }
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
                catch { privacy = nil; privacyIssue = error.localizedDescription }
            }
            result.resourceDeclarations = .init(info: plist, privacy: privacy, privacyIssue: privacyIssue)
        }
        let finalPlist = try metadata(plistFD), finalRoot = try metadata(fd)
        if !same(plistStat, finalPlist) || !same(rootStat, finalRoot) {
            result.resourceDeclarations = nil
            result.partial = true; row("[bundle-changed]", "changed", "App root or Info.plist changed during discovery.")
        }
        let partial = result.partial, cancelled = result.cancelled
        for index in result.entries.indices {
            guard var provenance = result.entries[index].provenance else { continue }
            provenance.inventoryPartial = partial
            provenance.inventoryCancelled = cancelled
            result.entries[index].provenance = provenance
        }
        return result
    }

    public static func validate(_ provenance: BundleImageProvenance, input: URL) throws {
        try withValidatedImage(provenance, input: input) { _ in () }
    }

    /// Keeps the same no-follow descriptor open through the caller's bounded read.
    static func withValidatedImage<T>(_ provenance: BundleImageProvenance, input: URL,
                                      body: (Int32) throws -> T) throws -> T {
        let scanner = BundleDiscovery()
        let components = provenance.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3, components.allSatisfy(scanner.safe), components[0] == "Contents",
              provenance.relativePath.utf8.count <= 4096,
              provenance.bundle.appendingPathComponent(provenance.relativePath).standardizedFileURL == input.standardizedFileURL else { throw scanner.failure("Invalid bundle provenance path.") }
        let root = Darwin.open(provenance.bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw scanner.failure("Bundle root unavailable or replaced by a link.") }; defer { Darwin.close(root) }
        let rootStat = try scanner.metadata(root)
        guard UInt64(UInt32(bitPattern: rootStat.st_dev)) == provenance.rootDevice, rootStat.st_ino == provenance.rootInode else { throw scanner.failure("Bundle root changed since discovery.") }
        let file = try scanner.openRelative(root, components: components, directory: false); defer { Darwin.close(file) }
        let info = try scanner.metadata(file), expected = provenance.fileIdentity
        guard (info.st_mode & S_IFMT) == S_IFREG, input.path == expected.path,
              UInt64(UInt32(bitPattern: info.st_dev)) == expected.device, info.st_ino == expected.inode,
              info.st_size == expected.size, Int64(info.st_mtimespec.tv_sec) == expected.modifiedSeconds,
              Int64(info.st_mtimespec.tv_nsec) == expected.modifiedNanos,
              Int64(info.st_ctimespec.tv_sec) == expected.changedSeconds, Int64(info.st_ctimespec.tv_nsec) == expected.changedNanos else { throw scanner.failure("Discovered image changed; discover and select it again.") }
        let result = try body(file)
        guard scanner.same(info, try scanner.metadata(file)) else { throw scanner.failure("Image changed during metadata read.") }
        return result
    }

    static func readMetadata(_ provenance: BundleImageProvenance, relativePath: String) throws -> Data {
        let scanner = BundleDiscovery()
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(scanner.safe), relativePath.utf8.count <= 4096 else { throw scanner.failure("Invalid metadata path.") }
        let root = Darwin.open(provenance.bundle.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw scanner.failure("Bundle root unavailable.") }; defer { Darwin.close(root) }
        let info = try scanner.metadata(root)
        guard UInt64(UInt32(bitPattern: info.st_dev)) == provenance.rootDevice, info.st_ino == provenance.rootInode else { throw scanner.failure("Bundle root changed.") }
        let file = try scanner.openRelative(root, components: parts, directory: false); defer { Darwin.close(file) }
        let before = try scanner.metadata(file)
        guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size > 0, before.st_size <= 65_536 else { throw scanner.failure("Metadata must be a bounded regular file.") }
        let bytes = try scanner.prefix(file, count: Int(before.st_size))
        guard scanner.same(before, try scanner.metadata(file)) else { throw scanner.failure("Metadata changed while reading.") }
        return bytes
    }

    private func openRelative(_ root: Int32, components: [String], directory: Bool) throws -> Int32 {
        var current = Darwin.dup(root)
        guard current >= 0 else { throw failure("Cannot duplicate directory descriptor.") }
        do {
            for (index, component) in components.enumerated() {
                let child = try openChild(current, name: component, directory: index < components.count - 1 || directory)
                Darwin.close(current); current = child
            }
            return current
        } catch { Darwin.close(current); throw error }
    }
    private func openChild(_ parent: Int32, name: String, directory: Bool) throws -> Int32 {
        guard safe(name) else { throw failure("Unsafe path component.") }
        let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : O_NONBLOCK)) }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; return fd
    }
    private func metadata(_ fd: Int32) throws -> stat {
        var info = stat(); guard Darwin.fstat(fd, &info) == 0 else { throw failure("Descriptor metadata unavailable.") }; return info
    }
    private func prefix(_ fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let read = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, 0) }
        guard read == count else { throw failure("Header changed or could not be read completely.") }; return Data(bytes)
    }
    private func safe(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") }
    private func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func failure(_ message: String) -> Error { ReportError.invalidContents(message) }

    // Header hints only. AIRS's owned parser remains the authority on valid slices.
    private static func classify(_ data: Data, size: UInt64) -> (Bool, String, String) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return (false, "non_image", "Not a Mach-O header.") }
        let magic = Array(bytes.prefix(4))
        func number(_ start: Int, little: Bool) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[start + $1]) << UInt32((little ? $1 : 3 - $1) * 8) }
        }
        let thin: [[UInt8]] = [[0xcf,0xfa,0xed,0xfe],[0xfe,0xed,0xfa,0xcf],[0xce,0xfa,0xed,0xfe],[0xfe,0xed,0xfa,0xce]]
        if thin.contains(magic) {
            guard bytes.count >= (magic.contains(0xcf) ? 32 : 28) else { return (false, "malformed_header", "Truncated Mach-O header.") }
            let little = magic[0] == 0xcf || magic[0] == 0xce
            let cpu = number(4, little: little), subtype = number(8, little: little), type = number(12, little: little)
            guard [UInt32(2),6,8].contains(type) else { return (false, "unsupported_type", "Mach-O type \(type) is not a final executable, dylib or bundle.") }
            return (true, "candidate", "Mach-O header · CPU \(String(cpu, radix: 16)) / subtype \(subtype) · type \(type). Parser validation pending.")
        }
        let fat: [[UInt8]] = [[0xca,0xfe,0xba,0xbe],[0xbe,0xba,0xfe,0xca],[0xca,0xfe,0xba,0xbf],[0xbf,0xba,0xfe,0xca]]
        if fat.contains(magic) {
            guard bytes.count >= 8 else { return (false, "malformed_header", "Truncated universal header.") }
            let little = magic[0] == 0xbe || magic[0] == 0xbf
            let count = number(4, little: little), stride = (magic.contains(0xbf) ? 32 : 20)
            guard count > 0, count <= 64, UInt64(8 + Int(count) * stride) <= size, 8 + Int(count) * stride <= bytes.count else { return (false, "malformed_header", "Universal directory exceeds the bounded header or file.") }
            let cpus = (0..<Int(count)).map { "0x" + String(number(8 + $0 * stride, little: little), radix: 16) }
            return (true, "candidate", "Universal header · \(count) slices · CPUs \(cpus.joined(separator: ", ")). Slice validation pending.")
        }
        return (false, "non_image", "Not a Mach-O header.")
    }
}
