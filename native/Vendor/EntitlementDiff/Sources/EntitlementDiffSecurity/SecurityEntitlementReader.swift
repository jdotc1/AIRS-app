import CoreFoundation
import Foundation
import Security
import EntitlementDiffCore

public enum NativeInspectionError: Error, Sendable, LocalizedError {
    case systemCall(operation: String, status: Int32, architecture: Architecture)
    case architectureUnavailable(Architecture)
    case missingResult
    case executableMismatch

    public var errorDescription: String? {
        switch self {
        case let .systemCall(operation, status, architecture):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "No system description"
            return "\(operation) failed for requested \(architecture.rawValue) (OSStatus \(status)): \(detail). The app may lack that architecture or have unreadable/malformed signing data. No fallback slice was used."
        case .architectureUnavailable(let architecture):
            return "The main executable does not advertise the requested \(architecture.rawValue) architecture. No fallback slice was used."
        case .missingResult:
            return "Security.framework returned no usable signing-information dictionary."
        case .executableMismatch:
            return "The executable reported by Security.framework does not match the preflight selection. The bundle may have changed during inspection."
        }
    }
}

/// Owns native handles on a serial actor. Synchronous Security calls never run
/// on MainActor. Cancellation discards results but cannot interrupt an OS call.
public actor SecurityEntitlementReader: SnapshotReading {
    private let metadataDecoder: SigningMetadataDecoder
    public init(limits: DecodeLimits = .init()) { metadataDecoder = .init(limits: limits) }

    public func read(at url: URL, architecture: Architecture) async throws -> EntitlementSnapshot {
        try Task.checkCancellation()
        // Non-sandboxed URLs commonly return false. That is not an access-denied
        // verdict; attempt the read and let normal filesystem errors decide.
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        let location = try AppBundlePreflight.inspect(url)
        try Task.checkCancellation()

        // Security's architecture attribute is ignored for non-Mach-O code.
        // A magic prefix is not enough. Ask the public CFBundle API to identify
        // this exact executable, without loading it or constructing a cached Bundle.
        guard let architectures = CFBundleCopyExecutableArchitecturesForURL(location.executableURL as CFURL) as? [NSNumber],
              !architectures.isEmpty else { throw BundleInputError.machORequired }
        let requestedCPU = architecture == .arm64 ? kCFBundleExecutableArchitectureARM64 : kCFBundleExecutableArchitectureX86_64
        guard architectures.contains(where: { $0.intValue == requestedCPU }) else {
            throw NativeInspectionError.architectureUnavailable(architecture)
        }

        let attributes = [kSecCodeAttributeArchitecture as String: architecture.rawValue] as CFDictionary
        let flags = SecCSFlags(rawValue: 0) // kSecCSDefaultFlags in CSCommon.h
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPathAndAttributes(location.bundleURL as CFURL, flags, attributes, &staticCode)
        guard createStatus == errSecSuccess else {
            throw NativeInspectionError.systemCall(operation: "Create static code", status: createStatus, architecture: architecture)
        }
        guard let staticCode else { throw NativeInspectionError.missingResult }
        var rawInformation: CFDictionary?
        // Default/generic information includes entitlements and signing identifier.
        // Do not ask for certificate/trust, dynamic-process, or internal information.
        let status = SecCodeCopySigningInformation(staticCode, flags, &rawInformation)
        if status == errSecCSUnsigned { throw SigningMetadataError.unsigned }
        guard status == errSecSuccess else {
            throw NativeInspectionError.systemCall(operation: "Extract signing metadata", status: status, architecture: architecture)
        }
        guard let information = rawInformation as? [String: Any] else { throw NativeInspectionError.missingResult }
        let metadata = try metadataDecoder.decode(
            signingIdentifier: information[kSecCodeInfoIdentifier as String],
            entitlementDictionary: information[kSecCodeInfoEntitlementsDict as String],
            hasRawEntitlements: information[kSecCodeInfoEntitlements as String] != nil
        )
        guard let actualExecutable = information[kSecCodeInfoMainExecutable as String] as? URL,
              actualExecutable.resolvingSymlinksInPath().standardizedFileURL.path.utf8
                .elementsEqual(location.executableURL.path.utf8) else { throw NativeInspectionError.executableMismatch }
        try Task.checkCancellation()
        return .init(sourceName: location.bundleURL.lastPathComponent, signingIdentifier: metadata.signingIdentifier,
                     architecture: architecture, presence: metadata.presence, entitlements: metadata.entitlements, identity: location.identity)
    }
}
