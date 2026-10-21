import XCTest
@testable import AIRSEntitlements

final class SigningSliceAssessmentTests:XCTestCase {
    func testNativeMixedUniversalPreservesArchitectureObservations() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/signing-slice-acceptance/\(UUID())")
        let retain=ProcessInfo.processInfo.environment["AIRS_SIGNING_ACCEPTANCE_OUTPUT"].map {URL(fileURLWithPath:$0)}
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)

        let source=root.appendingPathComponent("main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to:source)
        func tool(_ arguments:[String]) throws {
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/xcrun");task.arguments=arguments
            try task.run();task.waitUntilExit();XCTAssertEqual(task.terminationStatus,0)
        }
        let arm=root.appendingPathComponent("arm64"),intel=root.appendingPathComponent("x86_64")
        // The Apple arm64 linker's ordinary output contains an ad hoc signature.
        // No signing command is invoked or installed app changed.
        try tool(["clang","-arch","arm64",source.path,"-o",arm.path])
        try tool(["clang","-arch","x86_64","-Wl,-no_adhoc_codesign",source.path,"-o",intel.path])
        let mixed=root.appendingPathComponent("mixed")
        try tool(["lipo","-create",arm.path,intel.path,"-output",mixed.path])
        let checker=NativeAssessmentChecker()
        let result=try await checker.check(.signingInformation,at:mixed)
        XCTAssertEqual(result.outcome,.unavailable,result.diagnostic)
        XCTAssertTrue(result.diagnostic.contains("[arm64] passed:"),result.diagnostic)
        XCTAssertTrue(result.diagnostic.contains("adHoc=true"),result.diagnostic)
        XCTAssertTrue(result.diagnostic.contains("[x86_64] failed:"),result.diagnostic)
        XCTAssertTrue(result.diagnostic.contains("mixed signed/unsigned"),result.diagnostic)
        XCTAssertTrue(result.diagnostic.contains("subtypes unexamined"),result.diagnostic)
        print(result.diagnostic)
        if let retain {
            try FileManager.default.createDirectory(at:retain,withIntermediateDirectories:true)
            try Data(result.diagnostic.utf8).write(to:retain.appendingPathComponent("observations.txt"))
        }
        let subject=Data("Owned compiler/lipo mixed arm64 and x86_64 fixture; metadata extraction only".utf8),now=Date()
        let evidence=AssessmentEvidence(kind:.signingInformation,subjectDocumentDigest:AssessmentDocument.digest(subject),subjectFileDigest:nil,componentRelativePath:"@app-root",architecture:nil,scopeDescription:NativeAssessmentChecker.description(.signingInformation).2,startedAt:now,completedAt:now,hostOS:ProcessInfo.processInfo.operatingSystemVersionString,toolOrAPI:"SecCodeCopySigningInformation",argumentsOrFlags:NativeAssessmentChecker.description(.signingInformation).1,outcome:result.outcome,diagnostic:result.diagnostic)
        if let retain {try AssessmentDocument(subjectDocument:subject,results:[evidence]).archive().write(to:retain.appendingPathComponent("mixed-observations.airsreview"))}
        let thinSigned=try await checker.check(.signingInformation,at:arm)
        let thinUnsigned=try await checker.check(.signingInformation,at:intel)
        XCTAssertEqual(thinSigned.outcome,.passed,thinSigned.diagnostic)
        XCTAssertEqual(thinUnsigned.outcome,.failed,thinUnsigned.diagnostic)
    }
    func testMixedSyntheticSliceEvidenceSurvivesArchive() throws {
        let result=NativeAssessmentChecker.signingResult([
            .init(architecture:"arm64",outcome:.passed,diagnostic:"adHoc=true; identifier=owned"),
            .init(architecture:"x86_64",outcome:.failed,diagnostic:"Signing metadata OSStatus -67062; unsigned")])
        XCTAssertEqual(result.outcome,.unavailable)
        XCTAssertTrue(result.diagnostic.contains("mixed signed/unsigned"))
        XCTAssertTrue(result.diagnostic.contains("[arm64] passed: adHoc=true"))
        XCTAssertTrue(result.diagnostic.contains("[x86_64] failed:"))
        let source=Data("synthetic mixed-slice subject".utf8),now=Date()
        let evidence=AssessmentEvidence(kind:.signingInformation,subjectDocumentDigest:AssessmentDocument.digest(source),subjectFileDigest:nil,componentRelativePath:"@app-root",architecture:nil,scopeDescription:NativeAssessmentChecker.description(.signingInformation).2,startedAt:now,completedAt:now,hostOS:"synthetic",toolOrAPI:"synthetic",argumentsOrFlags:[],outcome:result.outcome,diagnostic:result.diagnostic)
        let archive=try InspectionArchive.decode(AssessmentDocument(subjectDocument:source,results:[evidence]).archive())
        let reopened=try AssessmentDocument.decode(archive.attachments[0].bytes)
        XCTAssertEqual(reopened.results[0].diagnostic,result.diagnostic)
        XCTAssertEqual(reopened.outcome(for:.signingInformation),.unavailable)
        XCTAssertEqual(reopened.outcome(for:.signatureValidity),.notPerformed)
    }
    func testUnexaminedAndDifferentMetadataNeverPass() {
        for other in [NativeAssessmentChecker.SigningSliceObservation(architecture:"x86_64",outcome:.unavailable,diagnostic:"Unexamined"),
                      .init(architecture:"x86_64",outcome:.passed,diagnostic:"team=other")] {
            XCTAssertEqual(NativeAssessmentChecker.signingResult([.init(architecture:"arm64",outcome:.passed,diagnostic:"adHoc=true"),other]).outcome,.unavailable)
        }
        XCTAssertEqual(NativeAssessmentChecker.signingResult([]).outcome,.unavailable)
    }
    func testThinAndUniformMetadataRetainExtractionOutcomes() {
        for count in [1,2] {
            XCTAssertEqual(NativeAssessmentChecker.signingResult((0..<count).map {.init(architecture:"slice-\($0)",outcome:.passed,diagnostic:"adHoc=true")}).outcome,.passed)
            XCTAssertEqual(NativeAssessmentChecker.signingResult((0..<count).map {.init(architecture:"slice-\($0)",outcome:.failed,diagnostic:"unsigned")}).outcome,.failed)
        }
    }
}
