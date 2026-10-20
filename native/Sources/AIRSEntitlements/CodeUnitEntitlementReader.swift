import Foundation
import AIRSCore
import EntitlementDiffCore
import EntitlementDiffSecurity

public protocol CodeUnitSnapshotReading: Sendable {
    func read(unit: BundleImageProvenance, architecture: Architecture) async throws -> EntitlementSnapshot
}
public struct CodeUnitEntitlementReader: CodeUnitSnapshotReading {
    private let extract: @Sendable (BundleCodeUnit, Architecture) async throws -> EntitlementSnapshot
    public init(extract: @escaping @Sendable (BundleCodeUnit, Architecture) async throws -> EntitlementSnapshot = { location, architecture in
        let plist = try PropertyListSerialization.propertyList(from: location.infoBytes, format: nil) as? [String: Any] ?? [:]
        return try await SecurityEntitlementReader().readCode(at: location.codeURL, executableURL: location.executableURL,
            architecture: architecture, sourceName: location.executableURL.lastPathComponent, identity: .init(infoPlist: plist))
    }) { self.extract = extract }
    public func read(unit: BundleImageProvenance, architecture: Architecture) async throws -> EntitlementSnapshot {
        try Task.checkCancellation()
        let location = try CodeUnitPreflight.inspect(unit)
        let discovery = try BundleDiscoveryEntry.forCodeUnit(unit)
        let metadata = try ComponentMetadataReader().read(discovery)
        guard metadata.architectures.contains(architecture.rawValue) else { throw NativeInspectionError.architectureUnavailable(architecture) }
        let result = try await extract(location, architecture)
        try Task.checkCancellation()
        try BundleDiscovery.validate(unit, input: location.executableURL)
        let after = try CodeUnitPreflight.inspect(unit)
        guard after.infoBytes == location.infoBytes, result.architecture == architecture,
              result.origin == .extracted, !result.isSavedBaseline else {
            throw ReportError.invalidContents("Code unit metadata or requested slice changed during extraction.")
        }
        return .init(sourceName: location.executableURL.lastPathComponent, signingIdentifier: result.signingIdentifier, architecture: architecture,
            presence: result.presence, origin: result.origin, entitlements: result.entitlements, identity: result.identity)
    }
}
