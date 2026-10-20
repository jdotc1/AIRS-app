import XCTest
import Foundation
@testable import AIRSEntitlements
final class AssessmentRunnerTests: XCTestCase {
    func testKnownMissingResourceSealIsFailureButOperationalErrorsUnavailable() {
        XCTAssertEqual(NativeAssessmentChecker.staticOutcome(-67056),.failed)
        XCTAssertEqual(NativeAssessmentChecker.staticOutcome(-50),.unavailable)
    }
    func testChangedInputRetainsRawDiagnosticButCannotPass() async throws {
        let root=try folder(); defer {try? FileManager.default.removeItem(at:root)}
        let identity=try AssessmentContentIdentity.capture(root)
        let runner=AssessmentRunner(checker:FixtureChecker { _,url in
            try Data("changed".utf8).write(to:url.appendingPathComponent("new-resource")); return .init(.passed,"raw owned pass")
        })
        let result=await runner.run(.signatureValidity,identity:identity,documentDigest:"owned")
        XCTAssertEqual(result.outcome,.unavailable); XCTAssertNil(result.subjectFileDigest)
        XCTAssertTrue(result.diagnostic.contains("raw owned pass"))
    }
    func testMissingBackendAndCancellationAreNotFailures() async throws {
        let root=try folder(); defer {try? FileManager.default.removeItem(at:root)}
        let identity=try AssessmentContentIdentity.capture(root)
        let absent=AssessmentRunner(checker:FixtureChecker {_,_ in throw CocoaError(.fileNoSuchFile)})
        let unavailable=await absent.run(.localDistribution,identity:identity,documentDigest:"owned")
        XCTAssertEqual(unavailable.outcome,.unavailable)
        let cancelled=AssessmentRunner(checker:FixtureChecker {_,_ in throw CancellationError()})
        let result=await cancelled.run(.signatureValidity,identity:identity,documentDigest:"owned")
        XCTAssertEqual(result.outcome,.cancelled)
    }
    func testOwnedProcessMissingToolCancellationAndOutputBound() async throws {
        do { _=try await AssessmentProcess(executable:URL(fileURLWithPath:"/owned/missing-spctl"),arguments:[]).run(); XCTFail("Missing tool") } catch {}
        let process=AssessmentProcess(executable:URL(fileURLWithPath:"/bin/sleep"),arguments:["30"])
        let task=Task { try await process.run() }; task.cancel()
        do { let result=try await task.value; XCTAssertNotNil(result.interruption) } catch {XCTAssertTrue(error is CancellationError)}
        let flood=try await AssessmentProcess(executable:URL(fileURLWithPath:"/usr/bin/yes"),arguments:[],timeout:2).run()
        XCTAssertNotNil(flood.interruption); XCTAssertLessThanOrEqual(flood.diagnostic.utf8.count,65537)
    }
    func testExitedHelperWithInheritedPipeSettlesWithinDrainDeadline() async throws {
        let root=try folder(); defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("pipe.c"), helper=root.appendingPathComponent("pipe-helper")
        try Data("#include <unistd.h>\nint main(void) { if (fork() == 0) { sleep(4); _exit(0); } return 0; }\n".utf8).write(to:source)
        let compiler=Process(); compiler.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");compiler.arguments=["clang",source.path,"-o",helper.path]
        try compiler.run();compiler.waitUntilExit();XCTAssertEqual(compiler.terminationStatus,0)
        let start=Date()
        let result=try await AssessmentProcess(executable:helper,arguments:[],timeout:0.2).run()
        XCTAssertLessThan(Date().timeIntervalSince(start),2.5)
        XCTAssertNotNil(result.interruption)
    }
    func testNativeOwnedValidUnsignedAndTamperedFixtures() async throws {
        let root=try folder(); defer {try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("main.c"); try Data("int main(void) { return 0; }\n".utf8).write(to:source)
        let valid=root.appendingPathComponent("valid"), unsigned=root.appendingPathComponent("unsigned"), invalid=root.appendingPathComponent("invalid")
        for (url,arch,extra) in [(valid,"arm64",[String]()),(unsigned,"x86_64",["-Wl,-no_adhoc_codesign"])] {
            let p=Process(); p.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun"); p.arguments=["clang","-arch",arch,source.path,"-o",url.path]+extra
            try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus,0)
        }
        var bytes=try Data(contentsOf:valid)
        func u32(_ i:Int) -> Int { (0..<4).reduce(0){$0 | Int(bytes[i+$1]) << (8*$1)} }
        var offset=32, text:Int?
        for _ in 0..<u32(16) {
            if u32(offset)==0x19 {
                for index in 0..<u32(offset+64) {
                    let section=offset+72+index*80
                    if String(decoding:bytes[section..<section+16].prefix(while:{$0 != 0}),as:UTF8.self)=="__text" {text=u32(section+48)}
                }
            }
            offset += u32(offset+4)
        }
        bytes[try XCTUnwrap(text)] ^= 1; try bytes.write(to:invalid)
        let checker=NativeAssessmentChecker()
        let metadata=try await checker.check(.signingInformation,at:valid)
        XCTAssertEqual(metadata.outcome,.passed); XCTAssertTrue(metadata.diagnostic.contains("adHoc=true"))
        let good=try await checker.check(.signatureValidity,at:valid)
        let noSignature=try await checker.check(.signatureValidity,at:unsigned)
        let tampered=try await checker.check(.signatureValidity,at:invalid)
        XCTAssertEqual(good.outcome,.passed,good.diagnostic)
        XCTAssertEqual(noSignature.outcome,.failed,noSignature.diagnostic)
        XCTAssertEqual(tampered.outcome,.failed,tampered.diagnostic)
    }
    private func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AIRS-source-tests/\(UUID())/AIRS-assessments-20261020/tests/\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("owned".utf8).write(to:root.appendingPathComponent("resource")); return root
    }
}
private struct FixtureChecker: AssessmentChecking {
    let body:@Sendable (AssessmentKind,URL) async throws -> AssessmentCheckResult
    init(_ body:@escaping @Sendable (AssessmentKind,URL) async throws -> AssessmentCheckResult) {self.body=body}
    func check(_ kind:AssessmentKind,at url:URL) async throws -> AssessmentCheckResult {try await body(kind,url)}
}
