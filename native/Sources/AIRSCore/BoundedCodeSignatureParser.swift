// Adapted from EntitlementLens CodeSignatureParser.swift and MachOByteRange.swift.
// Copyright (c) 2026 hideouts-io. MIT License; see third_party/EntitlementLens/LICENSE.
// Pinned source and AIRS-specific changes: third_party/EntitlementLens/UPSTREAM.md.
import Foundation

enum BoundedCodeSignatureError: Error { case malformed, slotBudget }

/// Pure bounded byte parsing. All records participate in range and uniqueness
/// checks, even when their type is not an entitlement slot. No decoded plist,
/// DER interpretation, Security-framework dictionary or trust result is used.
enum BoundedCodeSignatureParser {
    static func parse(_ data: Data, containerOffset: UInt64, sliceOffset: UInt64,
                      maximumSlotCount: Int) throws -> [CodeSignatureEntitlementBlob] {
        guard data.count <= 512 * 1_024, maximumSlotCount <= 4096 else { throw BoundedCodeSignatureError.malformed }
        let bytes = [UInt8](data)
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count, 4 <= bytes.count - offset else { throw BoundedCodeSignatureError.malformed }
            return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard bytes.count >= 12, try word(0) == 0xfade0cc0,
              containerOffset >= sliceOffset, UInt64(bytes.count) <= UInt64.max - containerOffset else {
            throw BoundedCodeSignatureError.malformed
        }
        let declaredLength = Int(try word(4)), count = Int(try word(8))
        guard declaredLength >= 12, declaredLength <= bytes.count,
              count <= (declaredLength - 12) / 8 else { throw BoundedCodeSignatureError.malformed }
        guard maximumSlotCount > 0, count <= maximumSlotCount else { throw BoundedCodeSignatureError.slotBudget }
        let indexEnd = 12 + count * 8
        struct Record { let type: UInt32; let magic: UInt32; let offset: Int; let length: Int }
        var records: [Record] = [], types = Set<UInt32>()
        for index in 0..<count {
            let type = try word(12 + index * 8), offset = Int(try word(16 + index * 8))
            guard types.insert(type).inserted, offset >= indexEnd, offset <= declaredLength,
                  8 <= declaredLength - offset else { throw BoundedCodeSignatureError.malformed }
            let magic = try word(offset), length = Int(try word(offset + 4))
            guard length >= 8, length <= declaredLength - offset,
                  type != 5 || magic == 0xfade7171,
                  type != 7 || magic == 0xfade7172,
                  magic != 0xfade7171 || type == 5,
                  magic != 0xfade7172 || type == 7 else { throw BoundedCodeSignatureError.malformed }
            records.append(.init(type: type, magic: magic, offset: offset, length: length))
        }
        let ordered = records.sorted { $0.offset < $1.offset }
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            guard next.offset >= previous.offset + previous.length else { throw BoundedCodeSignatureError.malformed }
        }
        return records.filter { $0.type == 5 || $0.type == 7 }.map { record in
            let raw = Data(bytes[record.offset..<(record.offset + record.length)])
            let offset = containerOffset + UInt64(record.offset)
            return .init(type: record.type, magic: record.magic, containerOffset: offset,
                sliceRelativeOffset: offset - sliceOffset, byteCount: UInt64(record.length),
                sha256: signatureEvidenceSHA256(raw), bytes: raw)
        }
    }
}
