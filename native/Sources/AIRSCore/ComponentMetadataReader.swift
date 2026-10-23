import Darwin
import Foundation

/// Narrow adaptation of owner-authored MacScope strictUniversalSlices,
/// parseBuildVersionCommand and parseMinimumOSVersionCommand. Unlike the donor's
/// whole-file/ARM64 loader this reads descriptor-bound metadata for every slice.
public struct ComponentMetadataReader: Sendable {
    private let maximumHeaderBytes: Int
    public private(set) var bytesRead = 0
    public private(set) var observedArchitectures: [String] = []
    private var captureLoadCommands = false
    private var loadDeclarations: [ComponentLoadDeclaration] = []
    private var captureSignatureLocations = false
    private var signatureLocations: [CodeSignatureSliceLocation] = []
    public mutating func readLoadCommands(_ candidate: BundleDiscoveryEntry) throws -> [ComponentLoadDeclaration] {
        bytesRead = 0; loadDeclarations = []; captureLoadCommands = true
        observedArchitectures = try readConsuming(candidate).architectures
        return loadDeclarations
    }
    public init(maximumHeaderBytes: Int = 1_048_576) { self.maximumHeaderBytes = maximumHeaderBytes }
    /// Internal descriptor-only seam: callers keep the discovery capability open
    /// across exact slice enumeration, bounded signature reads and source hashing.
    mutating func readSignatureLocations(fileDescriptor: Int32, fileSize: UInt64) throws -> [CodeSignatureSliceLocation] {
        guard maximumHeaderBytes > 0, maximumHeaderBytes <= 1_048_576 else { throw invalid("Invalid signature metadata budget.") }
        bytesRead = 0; signatureLocations = []; captureLoadCommands = false; captureSignatureLocations = true
        defer { captureSignatureLocations = false }
        _ = try parse(fileDescriptor, size: fileSize)
        return signatureLocations
    }
    public func read(_ candidate: BundleDiscoveryEntry) throws -> ComponentRecord {
        var reader = self
        return try reader.readConsuming(candidate)
    }
    mutating func readConsuming(_ candidate: BundleDiscoveryEntry) throws -> ComponentRecord {
        guard let provenance = candidate.provenance, maximumHeaderBytes >= 0, maximumHeaderBytes <= 1_048_576 else { throw invalid("No current discovery provenance or metadata budget.") }
        return try BundleDiscovery.withValidatedImage(provenance, input: provenance.bundle.appendingPathComponent(candidate.relativePath)) { fd in
            let size = provenance.fileIdentity.size
            guard size > 0 else { throw invalid("Empty image.") }
            let declarations = try parse(fd, size: UInt64(size))
            var issues = declarations.issues, identifier: String?, version: String?
            let path = candidate.relativePath, container = Self.container(for: path)
            let principal = candidate.message.contains("Principal executable")
            var recordKind = principal ? "app" : (container.isEmpty ? Self.kind(for: path) : "image")
            let plistPath: String?
            if principal { plistPath = "Contents/Info.plist" }
            else if !container.isEmpty {
                if container.hasSuffix(".framework") {
                    let suffix = String(path.dropFirst(container.count + 1)).split(separator: "/").map(String.init)
                    let versionPrefix = suffix.count >= 3 && suffix[0] == "Versions" ? "/Versions/" + suffix[1] : ""
                    plistPath = container + versionPrefix + "/Resources/Info.plist"
                } else { plistPath = container + "/Contents/Info.plist" }
            } else { plistPath = nil }
            if let plistPath {
                do {
                    let data = try BundleDiscovery.readMetadata(provenance, relativePath: plistPath)
                    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw invalid("Metadata is not a dictionary.") }
                    guard let executable = plist["CFBundleExecutable"] as? String,
                          !executable.isEmpty, executable != ".", executable != "..", executable.utf8.count <= 255,
                          !executable.contains("/"), !executable.contains("\\"), !executable.contains("\0") else {
                        throw invalid("No safe declared bundle executable.")
                    }
                    let expected: String
                    if principal { expected = "Contents/MacOS/" + executable }
                    else if container.hasSuffix(".framework") {
                        expected = String(plistPath.dropLast("Resources/Info.plist".count)) + executable
                    } else { expected = container + "/Contents/MacOS/" + executable }
                    if !path.utf8.elementsEqual(expected.utf8) {
                        issues.append("This image is not at the container's exact declared executable path; own labels unavailable.")
                    } else {
                        recordKind = principal ? "app" : Self.kind(for: path)
                        func label(_ key: String) throws -> String? {
                            guard let value = plist[key] else { return nil }
                            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256,
                                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid("Invalid bounded metadata label: " + key) }
                            return text
                        }
                        identifier = try label("CFBundleIdentifier"); version = try label("CFBundleShortVersionString")
                        if identifier == nil || version == nil { issues.append("Some declared bundle labels are unavailable.") }
                    }
                } catch { issues.append("Bundle labels unavailable at " + plistPath + ".") }
            } else { issues.append("No containing bundle metadata for this naked image.") }
            return .init(id: candidate.id, relativePath: path, kind: recordKind, declaredBundleID: identifier,
                declaredVersion: version, architectures: declarations.architectures,
                minimumOSByArchitecture: declarations.minimums, readIssues: issues)
        }
    }

    static func container(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        let indices = parts.dropLast().indices.filter { part in
            ["app", "xpc", "appex", "framework", "bundle"].contains(URL(fileURLWithPath: parts[part]).pathExtension.lowercased())
        }
        guard let index = indices.last else { return "" }
        return parts[...index].joined(separator: "/")
    }
    static func kind(for path: String) -> String {
        let container = container(for: path)
        switch URL(fileURLWithPath: container).pathExtension.lowercased() {
        case "app": return "app"
        case "xpc": return "xpc"
        case "appex": return "extension"
        case "framework": return "framework"
        default: return path.hasPrefix("Contents/Helpers/") || path.hasPrefix("Contents/Library/LoginItems/") ? "helper" : "image"
        }
    }
    private struct Slice { let cpu: UInt32; let subtype: UInt32; let offset: UInt64; let size: UInt64 }
    private struct Declarations { var architectures: [String] = []; var minimums: [String: String] = [:]; var issues: [String] = [] }
    private func invalid(_ message: String) -> Error { ReportError.invalidContents(message) }
    private mutating func read(_ fd: Int32, offset: UInt64, count: Int, end: UInt64) throws -> [UInt8] {
        if Task.isCancelled { throw CancellationError() }
        guard count >= 0, count <= maximumHeaderBytes - bytesRead, offset <= end,
              UInt64(count) <= end - offset, offset <= UInt64(Int64.max) else { throw invalid("Header/load-command size, slice range or shared read budget exceeded.") }
        bytesRead += count
        var bytes = [UInt8](repeating: 0, count: count)
        let amount = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard amount == count else { throw invalid("Truncated header or unreadable metadata.") }
        return bytes
    }
    private func number(_ bytes: [UInt8], _ start: Int, _ width: Int = 4, little: Bool) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[start + $1]) << UInt64((little ? $1 : width - 1 - $1) * 8) }
    }
    private mutating func parse(_ fd: Int32, size: UInt64) throws -> Declarations {
        let first = try read(fd, offset: 0, count: 8, end: size)
        let magic = number(first, 0, little: false)
        var slices: [Slice] = []
        if [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) {
            let little = [0xbebafeca,0xbfbafeca].contains(magic), wide = [0xcafebabf,0xbfbafeca].contains(magic)
            let count = Int(number(first, 4, little: little)), stride = wide ? 32 : 20
            guard count > 0, count <= 64 else { throw invalid("Universal architecture count exceeds bounds.") }
            let table = try read(fd, offset: 8, count: count * stride, end: size), tableEnd = UInt64(8 + count * stride)
            var seen = Set<String>()
            for index in 0..<count {
                let base = index * stride
                let cpu = UInt32(number(table, base, little: little)), subtype = UInt32(number(table, base + 4, little: little))
                let offset = number(table, base + 8, wide ? 8 : 4, little: little)
                let length = number(table, base + (wide ? 16 : 12), wide ? 8 : 4, little: little)
                let alignment = number(table, base + (wide ? 24 : 16), little: little)
                // MacScope's strict universal-layout contract: bounded exponent,
                // header exclusion, non-overlap and capability-masked uniqueness.
                guard offset >= tableEnd, offset <= size, length > 0, length <= size - offset,
                      alignment <= 15, offset & ((UInt64(1) << alignment) - 1) == 0,
                      seen.insert("\(cpu):\(subtype & 0x00ffffff)").inserted else { throw invalid("Invalid, overlapping or ambiguous universal slice layout.") }
                if wide, number(table, base + 28, little: little) != 0 { throw invalid("Nonzero universal reserved field.") }
                slices.append(.init(cpu: cpu, subtype: subtype, offset: offset, size: length))
            }
            let ordered = slices.sorted { $0.offset < $1.offset }
            for (previous, next) in zip(ordered, ordered.dropFirst()) where next.offset < previous.offset + previous.size { throw invalid("Universal slice ranges overlap.") }
        } else { slices = [.init(cpu: 0, subtype: 0, offset: 0, size: size)] }
        var result = Declarations()
        for slice in slices {
            let metadata = try thin(fd, slice: slice, universal: slices.count > 1 || magic == 0xcafebabe || magic == 0xcafebabf || magic == 0xbebafeca || magic == 0xbfbafeca)
            guard !result.architectures.contains(metadata.0) else { throw invalid("Duplicate architecture declaration.") }
            result.architectures.append(metadata.0)
            if let minimum = metadata.1 { result.minimums[metadata.0] = minimum }
            result.issues += metadata.2
        }
        return result
    }
    private mutating func thin(_ fd: Int32, slice: Slice, universal: Bool) throws -> (String, String?, [String]) {
        let end = slice.offset + slice.size
        let prefix = try read(fd, offset: slice.offset, count: 4, end: end), magic = number(prefix, 0, little: false)
        guard [0xcffaedfe,0xfeedfacf,0xcefaedfe,0xfeedface].contains(magic) else { throw invalid("Unsupported or truncated thin header.") }
        let little = [0xcffaedfe,0xcefaedfe].contains(magic), wide = [0xcffaedfe,0xfeedfacf].contains(magic)
        let headerSize = wide ? 32 : 28, header = try read(fd, offset: slice.offset, count: headerSize, end: end)
        let cpu = UInt32(number(header, 4, little: little)), subtype = UInt32(number(header, 8, little: little))
        guard !universal || (cpu == slice.cpu && subtype == slice.subtype) else { throw invalid("Universal and thin architecture declarations disagree.") }
        guard (cpu & 0x03000000 != 0) == wide else { throw invalid("CPU ABI declaration disagrees with thin-header width.") }
        guard [2,6,8].contains(number(header, 12, little: little)) else { throw invalid("Not a final executable, dylib or bundle.") }
        let count = Int(number(header, 16, little: little)), commandBytes = Int(number(header, 20, little: little))
        guard count <= 4096, count <= commandBytes / 8 else { throw invalid("Load-command count exceeds its bounded region.") }
        let commands = try read(fd, offset: slice.offset + UInt64(headerSize), count: commandBytes, end: end)
        var position = 0, minimum: String?, issues: [String] = []
        var platformCommands = 0
        var localLoads: [(String,String,String?,String?,UInt32?)] = []
        let inspectSignature = captureSignatureLocations && cpu == 0x0100000c
            && [UInt32(0), 1, 2].contains(subtype & 0x00ffffff) && little && wide
        var signatureCommands = 0
        var signatureRange: (UInt64, UInt64)?
        var signatureProblem: CodeSignatureEvidenceProblem?
        func version(_ value: UInt64) -> String { "\((value >> 16) & 0xffff).\((value >> 8) & 0xff).\(value & 0xff)" }
        for _ in 0..<count {
            guard position <= commands.count - 8 else { throw invalid("Truncated load-command entry.") }
            let cmd = number(commands, position, little: little), length = Int(number(commands, position + 4, little: little))
            guard length >= 8, length % (wide ? 8 : 4) == 0, length <= commands.count - position else { throw invalid("Invalid bounded load-command size.") }
            if inspectSignature, cmd == 0x1d {
                signatureCommands += 1
                if signatureCommands > 1 {
                    signatureProblem = .duplicateCommand; signatureRange = nil
                } else if length != 16 {
                    signatureProblem = .invalidSignatureRange
                } else {
                    let offset = number(commands, position + 8, little: little)
                    let length = number(commands, position + 12, little: little)
                    if offset < UInt64(headerSize + commandBytes) || offset > slice.size || length == 0 || length > slice.size - offset {
                        signatureProblem = .invalidSignatureRange
                    } else { signatureRange = (slice.offset + offset, length) }
                }
            }
            if captureLoadCommands {
                let dylibs: [UInt64: String] = [0xc:"load",0x80000018:"weak",0x8000001f:"reexport",0x80000023:"upward",0x20:"lazy",0xd:"installName"]
                if let name = dylibs[cmd] {
                    guard length >= 24 else { throw invalid("Dylib command is smaller than 24 bytes.") }
                    let offset = Int(number(commands, position + 8, little: little))
                    let alternate = [UInt64(0xc),0x80000018].contains(cmd) && number(commands, position + 12, little: little) == 0x1a741800
                    guard !alternate || (length >= 28 && offset == 28) else { throw invalid("Invalid dylib-use command layout.") }
                    let path = try commandString(commands, position: position, length: length, offset: offset, minimum: alternate ? 28 : 24)
                    localLoads.append((name,path,version(number(commands,position+16,little:little)),version(number(commands,position+20,little:little)),alternate ? UInt32(number(commands,position+24,little:little)) : nil))
                } else if cmd == 0x8000001c {
                    guard length >= 12 else { throw invalid("Rpath command is smaller than 12 bytes.") }
                    localLoads.append(("rpath",try commandString(commands,position:position,length:length,offset:Int(number(commands,position+8,little:little)),minimum:12),nil,nil,nil))
                }
            }
            if [UInt64(0x32),0x24,0x25,0x2f,0x30].contains(cmd) {
                platformCommands += 1
                guard platformCommands == 1 else { throw invalid("Multiple platform/minimum commands are ambiguous.") }
            }
            var found: String?
            if cmd == 0x32 {
                guard length >= 24 else { throw invalid("LC_BUILD_VERSION is smaller than 24 bytes.") }
                let tools = number(commands, position + 20, little: little)
                guard tools <= UInt64((length - 24) / 8) else { throw invalid("LC_BUILD_VERSION does not contain all tool records.") }
                if number(commands, position + 8, little: little) == 1 { found = version(number(commands, position + 12, little: little)) }
                else { issues.append("Non-macOS build platform declaration; macOS minimum unavailable.") }
            } else if cmd == 0x24 {
                guard length >= 16 else { throw invalid("LC_VERSION_MIN_MACOSX is smaller than 16 bytes.") }
                found = version(number(commands, position + 8, little: little))
            }
            if [UInt64(0x25),0x2f,0x30].contains(cmd) {
                guard length >= 16 else { throw invalid("Truncated non-macOS minimum-version command.") }
                issues.append("Non-macOS legacy minimum-version declaration; macOS minimum unavailable.")
            }
            if let found {
                guard minimum == nil else { throw invalid("Multiple minimum-platform commands are ambiguous.") }
                minimum = found
            }
            position += length
        }
        guard position == commands.count else { throw invalid("Load-command count/size do not cover the declared region.") }
        let architecture: String
        switch (cpu, subtype) {
        case (0x0100000c, 0): architecture = "arm64"
        case (0x0100000c, 2): architecture = "arm64e"
        case (0x01000007, 3): architecture = "x86_64"
        case (0x01000007, 8): architecture = "x86_64h"
        case (7, 3): architecture = "i386"
        default: architecture = "cpu0x" + String(cpu, radix: 16) + "/subtype0x" + String(subtype, radix: 16); issues.append("Unknown CPU/subtype declaration retained without interpretation.")
        }
        if minimum == nil { issues.append("No unambiguous macOS minimum-version declaration.") }
        if captureLoadCommands {
            guard localLoads.count <= 4096 - loadDeclarations.count else { throw invalid("Loader declaration record budget exceeded.") }
            loadDeclarations += localLoads.map { .init(architecture: architecture, command: $0.0, path: $0.1, currentVersion: $0.2, compatibilityVersion: $0.3, useFlags: $0.4) }
        }
        if captureSignatureLocations {
            signatureLocations.append(.init(cpuType: cpu, cpuSubtype: subtype, headerMagic: UInt32(magic),
                sliceOffset: slice.offset, sliceSize: slice.size,
                loadCommandsEnd: slice.offset + UInt64(headerSize + commandBytes),
                signatureOffset: signatureRange?.0, signatureByteCount: signatureRange?.1,
                problem: signatureProblem))
        }
        return (architecture, minimum, issues)
    }
    private func commandString(_ bytes: [UInt8], position: Int, length: Int, offset: Int, minimum: Int) throws -> String {
        guard offset >= minimum, offset < length,
              let end = bytes[(position+offset)..<(position+length)].firstIndex(of: 0),
              end - (position+offset) <= 4096,
              let value = String(bytes: bytes[(position+offset)..<end], encoding: .utf8) else { throw invalid("Invalid bounded UTF-8 load-command string.") }
        return value
    }

}
