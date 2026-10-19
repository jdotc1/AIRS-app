import Foundation

public struct EngineConfiguration: Sendable {
    public let pythonExecutable: URL
    public let bootstrap: URL
    public let isBundled: Bool

    public init(pythonExecutable: URL, bootstrap: URL, isBundled: Bool = false) {
        self.pythonExecutable = pythonExecutable
        self.bootstrap = bootstrap
        self.isBundled = isBundled
    }

    public static func resolve(
        pythonSetting: String,
        useExternalPython: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> EngineConfiguration {
        let fileManager = FileManager.default
        let privateVersion = bundle.object(forInfoDictionaryKey: "AIRSPrivatePythonVersion") as? String
        let privateRoot = bundle.bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework")
        let privatePython = privateRoot.appendingPathComponent("Versions/3.15/bin/python3.15")
        let expectsPrivate = privateVersion != nil || fileManager.fileExists(atPath: privateRoot.path)
        let external = useExternalPython || environment["AIRS_USE_EXTERNAL_PYTHON"] == "1"
        var usingBundled = false
        let configuredPython = pythonSetting.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentPython = environment["AIRS_PYTHON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitPython = configuredPython.isEmpty ? environmentPython : configuredPython
        let python: URL
        if expectsPrivate && !external {
            guard privateVersion == "3.15.0", fileManager.isExecutableFile(atPath: privatePython.path),
                  privateRoot.resolvingSymlinksInPath().path.hasPrefix(bundle.bundleURL.resolvingSymlinksInPath().path + "/Contents/Frameworks/"),
                  privatePython.resolvingSymlinksInPath().path.hasPrefix(privateRoot.resolvingSymlinksInPath().path + "/"),
                  fileManager.fileExists(atPath: privateRoot.appendingPathComponent("Versions/3.15/lib/python3.15/encodings/__init__.py").path) else {
                throw EngineError.configuration("The app's private Python 3.15.0 runtime is missing or damaged. Rebuild or replace this app; no system interpreter was selected.")
            }
            python = privatePython
            usingBundled = true
        } else if !explicitPython.isEmpty {
            python = try absoluteFileURL(explicitPython, label: "Python executable")
            guard fileManager.isExecutableFile(atPath: python.path) else {
                throw EngineError.configuration(
                    "The configured Python executable cannot be run: \(python.path). " +
                    "Choose a Python 3.11 or newer executable in Settings."
                )
            }
        } else {
            if expectsPrivate {
                throw EngineError.configuration("Choose an explicit external Python executable, or turn off the development override to use the private runtime.")
            }
            let versions = ["3.15", "3.14", "3.13", "3.12", "3.11"]
            let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
                + versions.map { "/Library/Frameworks/Python.framework/Versions/\($0)/bin/python3" }
                + versions.map { "/opt/homebrew/bin/python\($0)" }
                + versions.map { "/usr/local/bin/python\($0)" }
            guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
                throw EngineError.configuration(
                    "Analysis needs a local Python 3.11 or newer interpreter. " +
                    "Open Settings and choose its executable, or set AIRS_PYTHON " +
                    "for a terminal launch. You can still open an existing audit JSON report."
                )
            }
            python = URL(fileURLWithPath: path)
        }

        let bootstrap: URL
        if let override = environment["AIRS_ENGINE_BOOTSTRAP"], !override.isEmpty {
            bootstrap = try absoluteFileURL(override, label: "Engine bootstrap")
        } else {
            let bundled = bundle.resourceURL?.appendingPathComponent("Engine/airs_cli.py")
            if let bundled, fileManager.fileExists(atPath: bundled.path) {
                bootstrap = bundled
            } else if expectsPrivate {
                throw EngineError.configuration("The app's owned engine source is missing. Rebuild or replace the app; the developer checkout was not used.")
            } else {
                #if DEBUG
                // Source-checkout discovery is only for development builds.
                bootstrap = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("airs_cli.py")
                #else
                throw EngineError.configuration("The app's owned engine source is missing. Rebuild or replace the app, or set AIRS_ENGINE_BOOTSTRAP for an explicit development override.")
                #endif
            }
        }
        let regular = try? bootstrap.resourceValues(forKeys: [.isRegularFileKey])
        let sourceDirectory = bootstrap.deletingLastPathComponent()
            .appendingPathComponent("src/airs", isDirectory: true)
        var sourceIsDirectory: ObjCBool = false
        guard regular?.isRegularFile == true,
              fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            throw EngineError.configuration(
                "The local analysis engine was not found. Build this checkout with " +
                "scripts/package-app.sh, or set AIRS_ENGINE_BOOTSTRAP to its " +
                "airs_cli.py. You can still open an existing audit JSON report."
            )
        }
        return EngineConfiguration(pythonExecutable: python, bootstrap: bootstrap, isBundled: usingBundled)
    }

    /// Python flags protect imports; these removals also protect native loader and
    /// framework-launcher selection. No inherited executable code search overrides.
    public static func isolatedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("DYLD_") && $0.key != "__PYVENV_LAUNCHER__" }
    }

    private static func absoluteFileURL(_ value: String, label: String) throws -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw EngineError.configuration("\(label) must be an absolute local path.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

public enum EngineError: LocalizedError {
    case configuration(String)
    case busy
    case launchFailed(String)
    case failed(status: Int32, diagnostic: String)
    case missingOutput

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .busy: return "An analysis command is already running. Cancel it or wait for it to finish."
        case .launchFailed(let detail): return "The local Python engine could not start. \(detail)"
        case .failed(let status, let diagnostic):
            let explanation: String
            switch status {
            case 1: explanation = "The command reported a nonzero result."
            case 2: explanation = "The engine rejected the input or command."
            case 3: explanation = "The engine reported an internal failure."
            default: explanation = "The engine exited with status \(status)."
            }
            return diagnostic.isEmpty ? explanation : "\(explanation)\n\n\(diagnostic)"
        case .missingOutput: return "The engine exited without writing its requested JSON report."
        }
    }
}
