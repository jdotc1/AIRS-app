import Foundation

public enum BundleInputError: Error, Sendable, Equatable, LocalizedError {
    case localApplicationRequired
    case unreadableBundle
    case invalidInfoPlist
    case oversizedInfoPlist
    case invalidExecutableName
    case pathEscapesBundle
    case regularExecutableRequired
    case machORequired

    public var errorDescription: String? {
        switch self {
        case .localApplicationRequired: "Select a local .app directory."
        case .unreadableBundle: "The selected application or its metadata could not be read."
        case .invalidInfoPlist: "Expected a conventional macOS application with a valid Contents/Info.plist and package type APPL."
        case .oversizedInfoPlist: "The application's Info.plist exceeds the 1 MiB input limit."
        case .invalidExecutableName: "CFBundleExecutable must name one file, not a path or traversal component."
        case .pathEscapesBundle: "Bundle metadata or the main executable resolves outside the selected application."
        case .regularExecutableRequired: "The application's main executable must be a readable regular file."
        case .machORequired: "Only Mach-O application executables are supported. Script-based apps are not inspected."
        }
    }
}

public struct AppBundleLocation: Sendable {
    public let bundleURL: URL
    public let executableURL: URL
    public let identity: AppIdentity
}

/// Conventional bundle layout preflight; not a Mach-O parser, signature check,
/// atomic snapshot, or protection against concurrent filesystem replacement.
public enum AppBundlePreflight {
    public static let maximumInfoPlistBytes = 1_024 * 1_024

    public static func inspect(_ url: URL) throws -> AppBundleLocation {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw BundleInputError.localApplicationRequired
        }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        guard root.pathExtension.lowercased() == "app" else { throw BundleInputError.localApplicationRequired }
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey]), rootValues.isDirectory == true else {
            throw BundleInputError.unreadableBundle
        }
        let plistURL = root.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath().standardizedFileURL
        guard contains(plistURL, in: root) else { throw BundleInputError.pathEscapesBundle }
        guard let values = try? plistURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw BundleInputError.invalidInfoPlist
        }
        let data: Data
        do { data = try boundedRead(plistURL, limit: maximumInfoPlistBytes) }
        catch let error as BundleInputError { throw error }
        catch { throw BundleInputError.unreadableBundle }
        let plist: [String: Any]
        do {
            guard let decoded = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  decoded["CFBundlePackageType"] as? String == "APPL" else { throw BundleInputError.invalidInfoPlist }
            plist = decoded
        } catch { throw BundleInputError.invalidInfoPlist }
        guard let name = plist["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw BundleInputError.invalidExecutableName
        }
        let executable = root.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false).resolvingSymlinksInPath().standardizedFileURL
        guard contains(executable, in: root) else { throw BundleInputError.pathEscapesBundle }
        guard let fileValues = try? executable.resourceValues(forKeys: [.isRegularFileKey]), fileValues.isRegularFile == true else {
            throw BundleInputError.regularExecutableRequired
        }
        let prefix: Data
        do {
            let file = try FileHandle(forReadingFrom: executable)
            defer { try? file.close() }
            prefix = try file.read(upToCount: 4) ?? Data()
        } catch { throw BundleInputError.regularExecutableRequired }
        let signatures: [[UInt8]] = [
            [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCE],
            [0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF],
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF], [0xBF, 0xBA, 0xFE, 0xCA]
        ]
        guard signatures.contains(Array(prefix)) else { throw BundleInputError.machORequired }
        return .init(bundleURL: root, executableURL: executable, identity: .init(infoPlist: plist))
    }

    private static func contains(_ child: URL, in root: URL) -> Bool {
        let base = root.pathComponents, candidate = child.pathComponents
        return candidate.count > base.count && zip(base, candidate).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    private static func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let chunk = try file.read(upToCount: min(65_536, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw BundleInputError.oversizedInfoPlist }
        return data
    }
}
