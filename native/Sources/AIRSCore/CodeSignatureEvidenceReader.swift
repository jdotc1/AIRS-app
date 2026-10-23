import CryptoKit
import Darwin
import Foundation

/// Exact descriptor-bound locations from the existing strict Mach-O inventory
/// reader. Intel/unknown slices are inventoried but have no signature parsing.
struct CodeSignatureSliceLocation {
    let cpuType: UInt32
    let cpuSubtype: UInt32
    let headerMagic: UInt32
    let sliceOffset: UInt64
    let sliceSize: UInt64
    let loadCommandsEnd: UInt64
    let signatureOffset: UInt64?
    let signatureByteCount: UInt64?
    let problem: CodeSignatureEvidenceProblem?
    var supported: Bool {
        cpuType == 0x0100000c && [UInt32(0), 1, 2].contains(cpuSubtype & 0x00ffffff) && headerMagic == 0xcffaedfe
    }
}

public struct CodeSignatureEvidenceReader: Sendable {
    public let limits: CodeSignatureEvidenceLimits
    public init(limits: CodeSignatureEvidenceLimits = .init()) { self.limits = limits }

    /// Selected Mach-O bytes are data only. One validated no-follow descriptor
    /// supplies all metadata, streaming digests and retained signature bytes.
    /// A stale, unreadable or globally over-budget image throws; it cannot become
    /// a successful-looking partial document or an assertion of missing evidence.
    public func capture(unit: BundleImageProvenance, componentID: UUID) throws -> CodeSignatureEvidence {
        try limits.validate()
        try Task.checkCancellation()
        let input = unit.bundle.appendingPathComponent(unit.relativePath)
        let evidence = try BundleDiscovery.withValidatedImage(unit, input: input) { fd in
            guard unit.fileIdentity.size > 0 else { throw CodeSignatureEvidenceError.unavailable }
            let size = UInt64(unit.fileIdentity.size)
            guard size <= limits.maximumContainerBytes else { throw CodeSignatureEvidenceError.budgetExceeded }
            var metadata = ComponentMetadataReader(maximumHeaderBytes: limits.maximumHeaderBytes)
            let locations = try metadata.readSignatureLocations(fileDescriptor: fd, fileSize: size)
            let hashes = try hash(fd, size: size, slices: locations)
            var slices: [CodeSignatureSliceEvidence] = [], retained = 0
            for (index, location) in locations.enumerated() {
                try Task.checkCancellation()
                func result(_ state: CodeSignatureEvidenceState, _ problem: CodeSignatureEvidenceProblem? = nil,
                            bytes: Data? = nil, slots: [CodeSignatureEntitlementBlob] = []) -> CodeSignatureSliceEvidence {
                    .init(index: index, cpuType: location.cpuType, cpuSubtype: location.cpuSubtype,
                        headerMagic: location.headerMagic, sliceOffset: location.sliceOffset, sliceSize: location.sliceSize,
                        sliceSHA256: hashes.slices[index], loadCommandsEnd: location.loadCommandsEnd,
                        state: state, problem: problem,
                        signatureOffset: location.signatureOffset, signatureByteCount: location.signatureByteCount,
                        signatureSHA256: bytes.map(signatureEvidenceSHA256), signatureBytes: bytes, slots: slots)
                }
                guard location.supported else { slices.append(result(.unexamined, .unsupportedArchitecture)); continue }
                if let problem = location.problem { slices.append(result(.malformed, problem)); continue }
                guard let offset = location.signatureOffset, let count = location.signatureByteCount else {
                    slices.append(result(.signatureAbsent)); continue
                }
                guard count <= UInt64(limits.maximumSignatureBytes), count <= UInt64(limits.maximumTotalSignatureBytes - retained) else {
                    slices.append(result(.budgetExceeded, .signatureBudget)); continue
                }
                let bytes = try read(fd, offset: offset, count: Int(count))
                retained += bytes.count
                do {
                    let slots = try BoundedCodeSignatureParser.parse(bytes, containerOffset: offset,
                        sliceOffset: location.sliceOffset, maximumSlotCount: limits.maximumSlotCount)
                    slices.append(result(slots.isEmpty ? .entitlementsAbsent : .collected, bytes: bytes, slots: slots))
                } catch BoundedCodeSignatureError.slotBudget {
                    slices.append(result(.budgetExceeded, .slotBudget, bytes: bytes))
                } catch BoundedCodeSignatureError.malformed {
                    slices.append(result(.malformed, .invalidSuperBlob, bytes: bytes))
                }
            }
            let evidence = CodeSignatureEvidence(componentID: componentID, componentRelativePath: unit.relativePath,
                containerSHA256: hashes.container, containerByteCount: size, bytesHashed: size,
                headerBytesRead: metadata.bytesRead, signatureBytesRead: retained, limits: limits, slices: slices)
            try evidence.validate()
            try Task.checkCancellation()
            return evidence
        }
        // The held descriptor can outlive a renamed ancestor. This final check
        // reads no payload; it only confirms that the discovery capability still
        // names the same root and file before publishing the descriptor's bytes.
        try BundleDiscovery.validate(unit, input: input)
        try Task.checkCancellation()
        return evidence
    }

    private func read(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset <= UInt64(Int64.max), count > 0, count <= max(64 * 1_024, limits.maximumSignatureBytes) else {
            throw CodeSignatureEvidenceError.budgetExceeded
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let amount = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard amount == count else { throw CodeSignatureEvidenceError.unavailable }
        return Data(bytes)
    }

    /// Container and slice digests share the same pass. Padding between FAT
    /// slices contributes to the container identity, never to a slice identity.
    private func hash(_ fd: Int32, size: UInt64, slices: [CodeSignatureSliceLocation]) throws -> (container: String, slices: [String]) {
        var container = SHA256(), sliceHashes = slices.map { _ in SHA256() }, offset: UInt64 = 0
        while offset < size {
            let count = Int(min(UInt64(64 * 1_024), size - offset))
            let bytes = try read(fd, offset: offset, count: count)
            container.update(data: bytes)
            let end = offset + UInt64(count)
            for (index, slice) in slices.enumerated() {
                let lower = max(offset, slice.sliceOffset), upper = min(end, slice.sliceOffset + slice.sliceSize)
                if lower < upper {
                    sliceHashes[index].update(data: bytes.subdata(in: Int(lower - offset)..<Int(upper - offset)))
                }
            }
            offset = end
        }
        return (container.finalize().map { String(format: "%02x", $0) }.joined(),
                sliceHashes.map { $0.finalize().map { String(format: "%02x", $0) }.joined() })
    }
}
