import Foundation
import Security
import AIRSCore

public struct AssessmentCheckResult: Sendable {
    public let outcome:AssessmentOutcome
    public let diagnostic:String
    public init(_ outcome:AssessmentOutcome,_ diagnostic:String) {self.outcome=outcome;self.diagnostic=diagnostic}
}
public protocol AssessmentChecking: Sendable {
    func check(_ kind:AssessmentKind,at url:URL) async throws -> AssessmentCheckResult
}
/// MacScope's typed verifier adapted without its plugin trust policy. The static
/// operation uses explicit strict/all-architecture/nested flags and no requirement.
public actor NativeAssessmentChecker: AssessmentChecking {
    public init() {}
    public static func description(_ kind:AssessmentKind) -> (String,[String],String) {
        switch kind {
        case .signingInformation: ("SecCodeCopySigningInformation",["kSecCSSigningInformation"],"Selected app signing metadata; Security default architecture only. No validity or distribution check.")
        case .signatureValidity: ("SecStaticCodeCheckValidityWithErrors",["kSecCSStrictValidate","kSecCSCheckAllArchitectures","kSecCSCheckNestedCode","requirement=nil","networkAccessNotRequested"],"Selected app sealed resources and nested code; all architectures advertised to Security. No distribution verdict.")
        case .localDistribution: ("/usr/sbin/spctl",["--assess","--type","execute","--verbose=4"],"Selected app execute-policy assessment on this host at this time. System services/network may be contacted; not a clean-Mac launch or universal safety verdict.")
        }
    }
    public func check(_ kind:AssessmentKind,at url:URL) async throws -> AssessmentCheckResult {
        try Task.checkCancellation()
        if kind == .localDistribution {
            let result=try await AssessmentProcess(executable:URL(fileURLWithPath:"/usr/sbin/spctl"),arguments:Self.description(kind).1+[url.path]).run()
            if let interruption=result.interruption {return .init(Task.isCancelled ? .cancelled : .unavailable,interruption+"\n"+result.diagnostic)}
            // spctl(8): 0 success, 3 denial; 1 operational error, 2 arguments,
            // 4 deprecated. Preserve diagnostics; never turn them into trust.
            let outcome:AssessmentOutcome = !result.exited ? .unavailable : (result.status == 0 ? .passed : (result.status == 3 ? .failed : .unavailable))
            return .init(outcome,"spctl raw exit \(result.status), normal exit \(result.exited).\n"+result.diagnostic)
        }
        var code:SecStaticCode?
        let create=SecStaticCodeCreateWithPath(url as CFURL,SecCSFlags(rawValue:0),&code)
        guard create == errSecSuccess, let code else {return .init(.unavailable,"Create static code OSStatus \(create).")}
        if kind == .signingInformation {
            var raw:CFDictionary?
            let status=SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw)
            guard status == errSecSuccess,let info=raw as? [String:Any] else {return .init(status == errSecCSUnsigned ? .failed : .unavailable,"Signing metadata OSStatus \(status). "+message(status))}
            // CSCommon.h kSecCodeSignatureAdhoc = 0x0002 is not imported into Swift.
            let flags=(info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
            let flagText=flags.map(String.init) ?? "unavailable"
            let adHoc=flags.map { String(($0 & 0x0002) != 0) } ?? "unavailable"
            let identifier=info[kSecCodeInfoIdentifier as String] as? String ?? "unavailable"
            let team=info[kSecCodeInfoTeamIdentifier as String] as? String ?? "unavailable"
            return .init(.passed,String(("Metadata extraction only. identifier=\(identifier); team=\(team); adHoc=\(adHoc); flags=\(flagText). No signature validity check performed.").prefix(16000)))
        }
        var error:Unmanaged<CFError>?
        let flags=SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckAllArchitectures|kSecCSCheckNestedCode)
        let status=SecStaticCodeCheckValidityWithErrors(code,flags,nil,&error)
        let detail=error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? message(status)
        return .init(Self.staticOutcome(status),"OSStatus \(status). "+String(detail.prefix(16000))+" Static check only; no effective-permissions or distribution verdict.")
    }
    static func staticOutcome(_ status:OSStatus) -> AssessmentOutcome {
        switch status {
        case errSecSuccess: .passed
        case errSecCSUnsigned,errSecCSSignatureFailed,errSecCSResourcesInvalid,errSecCSResourcesNotFound,errSecCSBadResource,errSecCSResourceRulesInvalid: .failed
        default: .unavailable
        }
    }
    private func message(_ status:OSStatus) -> String {SecCopyErrorMessageString(status,nil) as String? ?? "No system diagnostic."}
}
public actor AssessmentRunner {
    private var active=false
    private let checker:any AssessmentChecking
    public init(checker:any AssessmentChecking=NativeAssessmentChecker()) {self.checker=checker}
    public func run(_ kind:AssessmentKind,identity:AssessmentContentIdentity,documentDigest:String,componentRelativePath:String="@app-root") async -> AssessmentEvidence {
        let start=Date(), descriptor=NativeAssessmentChecker.description(kind)
        var outcome:AssessmentOutcome = .unavailable, diagnostic="", bound:String?
        if active {diagnostic="Another assessment is still settling."}
        else {
            active=true; defer {active=false}
            do {
                try Task.checkCancellation(); try identity.validate()
                let raw=try await checker.check(kind,at:identity.url)
                diagnostic=raw.diagnostic; outcome=raw.outcome
                try Task.checkCancellation(); try identity.validate(); bound=identity.digest
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? .cancelled : .unavailable
                diagnostic += "\n"+error.localizedDescription+" No current scoped content binding was established."
            }
        }
        return .init(kind:kind,subjectDocumentDigest:documentDigest,subjectFileDigest:bound,componentRelativePath:componentRelativePath,architecture:nil,
            scopeDescription:descriptor.2+" Content identity: SHA256 physical tree v1, regular file bytes, relative UTF-8 paths, modes/ownership/flags and extended attributes; no links/special files. Observed identity checks, not an atomic bundle snapshot.",
            startedAt:start,completedAt:Date(),hostOS:ProcessInfo.processInfo.operatingSystemVersionString,toolOrAPI:descriptor.0,
            argumentsOrFlags:descriptor.1,outcome:outcome,diagnostic:String(diagnostic.prefix(16000)))
    }
}
