import Foundation
import XCTest
@testable import AIRSCore

final class PrivatePythonTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func mockApp() throws -> (URL, Bundle, URL) {
        let root = project.appendingPathComponent("build/private-python-evidence/tests/\(UUID())"), app = root.appendingPathComponent("Owned.app")
        let python = app.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.15/bin/python3.15")
        let stdlib = app.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.15/lib/python3.15/encodings")
        let engine = app.appendingPathComponent("Contents/Resources/Engine")
        for directory in [python.deletingLastPathComponent(), stdlib, engine.appendingPathComponent("src/airs")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data().write(to: stdlib.appendingPathComponent("__init__.py"))
        try Data().write(to: engine.appendingPathComponent("airs_cli.py"))
        let info: [String: Any] = ["CFBundleIdentifier": "dev.airs.runtime-test.\(UUID())", "CFBundleExecutable": "AIRSApp", "CFBundlePackageType": "APPL", "AIRSPrivatePythonVersion": "3.15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return (root, try XCTUnwrap(Bundle(url: app)), python)
    }
    func testBundledDefaultIgnoresStaleSettingAndExternalOverrideIsExplicit() throws {
        let (root, bundle, python) = try mockApp(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try EngineConfiguration.resolve(pythonSetting: "/stale/python", environment: ["AIRS_PYTHON": "/another/stale/python"], bundle: bundle)
        XCTAssertTrue(result.isBundled); XCTAssertEqual(result.pythonExecutable, python)
        let external = root.appendingPathComponent("external-python")
        try FileManager.default.copyItem(at: python, to: external)
        let override = try EngineConfiguration.resolve(pythonSetting: external.path, useExternalPython: true, environment: [:], bundle: bundle)
        XCTAssertFalse(override.isBundled); XCTAssertEqual(override.pythonExecutable, external)
        XCTAssertThrowsError(try EngineConfiguration.resolve(pythonSetting: "", useExternalPython: true, environment: [:], bundle: bundle))
    }
    func testDamagedPackagedRuntimeAndMissingEngineNeverFallbackToSystemOrCheckout() throws {
        let (root, bundle, python) = try mockApp(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: python)
        XCTAssertThrowsError(try EngineConfiguration.resolve(pythonSetting: "/opt/homebrew/bin/python3", environment: [:], bundle: bundle))
        let (other, otherBundle, _) = try mockApp(); defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.removeItem(at: otherBundle.bundleURL.appendingPathComponent("Contents/Resources/Engine/airs_cli.py"))
        XCTAssertThrowsError(try EngineConfiguration.resolve(pythonSetting: "", environment: [:], bundle: otherBundle))
    }
    func testInheritedPythonAndNativeLoaderOverridesAreRemoved() {
        let cleaned = EngineConfiguration.isolatedEnvironment(["PYTHONPATH": "/untrusted", "PYTHONHOME": "/wrong", "PYTHONOPTIMIZE": "2", "DYLD_LIBRARY_PATH": "/wrong", "DYLD_INSERT_LIBRARIES": "/wrong", "__PYVENV_LAUNCHER__": "/system", "PATH": "/usr/bin:/bin", "HOME": "/owned"])
        XCTAssertEqual(cleaned, ["PATH": "/usr/bin:/bin", "HOME": "/owned"])
    }
    func testActualPrivateChildUsesIsolatedNoSiteNoBytecodeAndCancellationSettles() async throws {
        let runtime = project.appendingPathComponent("build/private-python-3.15.0/Python.framework/Versions/3.15/bin/python3.15")
        guard FileManager.default.isExecutableFile(atPath: runtime.path) else { throw XCTSkip("Prepare the owned private runtime before this first runtime qualification") }
        let root = project.appendingPathComponent("build/private-python-evidence/child/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("owned_probe.py"), pid = root.appendingPathComponent("pid")
        let body = """
        import sys,os,json,pathlib,time,hashlib,lzma,zlib,ssl,encodings
        args=sys.argv[1:]
        if args[-1].endswith('sleep'):
            pathlib.Path(\(String(reflecting: pid.path))).write_text(str(os.getpid()))
            time.sleep(60)
        output=pathlib.Path(args[args.index('--output')+1])
        output.write_text(json.dumps({'isolated':sys.flags.isolated,'no_site':sys.flags.no_site,'bytecode':sys.dont_write_bytecode,'prefix':sys.prefix,'paths':sys.path,'site_loaded':'site' in sys.modules}))
        """
        try Data(body.utf8).write(to: script)
        let configuration = EngineConfiguration(pythonExecutable: runtime, bootstrap: script, isBundled: true), runner = EngineRunner()
        let artifact = try await runner.run(.audit(input: root.appendingPathComponent("data")), configuration: configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: artifact.data) as? [String: Any])
        XCTAssertEqual(object["isolated"] as? Int, 1); XCTAssertEqual(object["no_site"] as? Int, 1)
        XCTAssertEqual(object["bytecode"] as? Bool, true); XCTAssertEqual(object["site_loaded"] as? Bool, false)
        XCTAssertTrue((object["prefix"] as? String)?.hasPrefix(project.appendingPathComponent("build/private-python-3.15.0").path) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("__pycache__").path))
        let job = Task { try await runner.run(.audit(input: root.appendingPathComponent("sleep")), configuration: configuration) }
        for _ in 0..<300 { if FileManager.default.fileExists(atPath: pid.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pid.path))
        job.cancel()
        do { _ = try await job.value; XCTFail("Cancelled owned child returned success") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation result: \(error)") }
    }
}
