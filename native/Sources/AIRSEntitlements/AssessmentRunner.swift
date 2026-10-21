import Foundation
import Security
import AIRSCore
import EntitlementDiffCore

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
        case .signingInformation: ("SecCodeCopySigningInformation",["kSecCSSigningInformation","kSecCodeAttributeArchitecture=advertised CPU type","no default architecture fallback"],"Selected principal executable signing metadata, explicitly selected per advertised CPU family (subtypes unexamined). Mixed or unexamined slices are unavailable; extraction success is not signature validity or a whole-app signing verdict.")
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
        if kind == .signingInformation { return try signingInformation(at:url) }
        var code:SecStaticCode?
        let create=SecStaticCodeCreateWithPath(url as CFURL,SecCSFlags(rawValue:0),&code)
        guard create == errSecSuccess, let code else {return .init(.unavailable,"Create static code OSStatus \(create).")}
        var error:Unmanaged<CFError>?
        let flags=SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckAllArchitectures|kSecCSCheckNestedCode)
        let status=SecStaticCodeCheckValidityWithErrors(code,flags,nil,&error)
        let detail=error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? message(status)
        return .init(Self.staticOutcome(status),"OSStatus \(status). "+String(detail.prefix(16000))+" Static check only; no effective-permissions or distribution verdict.")
    }
    // Keep observations in the existing diagnostic/archive contract. Never let
    // default-architecture metadata stand in for the universal container.
    private func signingInformation(at url:URL) throws -> AssessmentCheckResult {
        let executable:URL
        do { executable = url.pathExtension.lowercased() == "app" ? try AppBundlePreflight.inspect(url).executableURL : url }
        catch { return .init(.unavailable,"Signing coverage unexamined: principal executable preflight failed: \(error.localizedDescription)") }
        guard let cpus=CFBundleCopyExecutableArchitecturesForURL(executable as CFURL) as? [NSNumber],
              !cpus.isEmpty, cpus.count <= 64 else {
            return .init(.unavailable,"Signing coverage unexamined: no bounded executable architecture inventory.")
        }
        var observations:[SigningSliceObservation]=[]
        var seen=Set<Int>()
        for cpu in cpus {
            try Task.checkCancellation()
            let name:String
            switch cpu.intValue {
            case kCFBundleExecutableArchitectureARM64: name="arm64"
            case kCFBundleExecutableArchitectureX86_64: name="x86_64"
            default:
                observations.append(.init(architecture:"cpu=\(cpu)",outcome:.unavailable,diagnostic:"Unexamined unsupported architecture; no default fallback.")); continue
            }
            guard seen.insert(cpu.intValue).inserted else {
                observations.append(.init(architecture:name+" additional subtype",outcome:.unavailable,diagnostic:"Duplicate CPU family; exact slice unexamined. No repeated family result substituted."));continue
            }
            var code:SecStaticCode?
            let attributes=[kSecCodeAttributeArchitecture as String:cpu] as CFDictionary
            let create=SecStaticCodeCreateWithPathAndAttributes(url as CFURL,SecCSFlags(rawValue:0),attributes,&code)
            guard create == errSecSuccess,let code else {
                observations.append(.init(architecture:name,outcome:.unavailable,diagnostic:"Create static code OSStatus \(create); no fallback."));continue
            }
            var raw:CFDictionary?
            let status=SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw)
            guard status == errSecSuccess,let info=raw as? [String:Any] else {
                observations.append(.init(architecture:name,outcome:status == errSecCSUnsigned ? .failed : .unavailable,diagnostic:"Signing metadata OSStatus \(status). "+message(status)));continue
            }
            // SecCode.h: identifier is always absent for unsigned code, even
            // when CopySigningInformation succeeds with generic information.
            guard info[kSecCodeInfoIdentifier as String] != nil else {
                observations.append(.init(architecture:name,outcome:.failed,diagnostic:"Signing metadata OSStatus 0; unsigned (Security signing identifier absent)."));continue
            }
            guard info[kSecCodeInfoIdentifier as String] is String else {
                observations.append(.init(architecture:name,outcome:.unavailable,diagnostic:"Signing metadata OSStatus 0; malformed signing identifier; signature state unresolved."));continue
            }
            let flags=(info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
            let flagText=flags.map(String.init) ?? "unavailable"
            let adHoc=flags.map {String(($0 & 0x0002) != 0)} ?? "unavailable"
            func bounded(_ value:String?) -> String {
                let text=value ?? "unavailable"
                return text.utf8.count > 256 ? String(decoding:text.utf8.prefix(256),as:UTF8.self)+" [truncated]" : text
            }
            let identifier=bounded(info[kSecCodeInfoIdentifier as String] as? String)
            let team=bounded(info[kSecCodeInfoTeamIdentifier as String] as? String)
            observations.append(.init(architecture:name,outcome:.passed,diagnostic:"identifier=\(identifier); team=\(team); adHoc=\(adHoc); flags=\(flagText)."))
        }
        if cpus.count > 1 {
            observations.append(.init(architecture:"container",outcome:.unavailable,diagnostic:"CPU-family inventory does not establish exact subtype/slice coverage. Other slices remain unexamined; no whole-container verdict."))
        }
        return Self.signingResult(observations)
    }
    struct SigningSliceObservation:Sendable {
        let architecture:String
        let outcome:AssessmentOutcome
        let diagnostic:String
    }
    static func signingResult(_ rows:[SigningSliceObservation]) -> AssessmentCheckResult {
        let complete = !rows.isEmpty && rows.allSatisfy {$0.outcome == .passed || $0.outcome == .failed}
        let allMetadata = complete && rows.allSatisfy {$0.outcome == .passed}
        let allUnsigned = complete && rows.allSatisfy {$0.outcome == .failed}
        let metadataDiffer = allMetadata && Set(rows.map(\.diagnostic)).count > 1
        let outcome:AssessmentOutcome = allMetadata && !metadataDiffer ? .passed : (allUnsigned ? .failed : .unavailable)
        let mixed = rows.contains {$0.outcome == .passed} && rows.contains {$0.outcome == .failed}
        let coverage = (!complete ? "partial/unexamined" : "complete") + (mixed ? "; mixed signed/unsigned" : (metadataDiffer ? "; mixed metadata" : ""))
        return .init(outcome,"Principal executable signing metadata coverage: \(coverage). Coverage entries (CPU-family observations; subtypes unexamined): \(rows.count). Metadata extraction only; no signature validity, nested-code or whole-app signing verdict.\n"+rows.map {"[\($0.architecture)] \($0.outcome.rawValue): \($0.diagnostic)"}.joined(separator:"\n"))
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
            argumentsOrFlags:descriptor.1,outcome:outcome,diagnostic:diagnostic.utf8.count <= 65000 ? diagnostic : String(decoding:diagnostic.utf8.prefix(65000),as:UTF8.self)+" [diagnostic truncated]")
    }
}
