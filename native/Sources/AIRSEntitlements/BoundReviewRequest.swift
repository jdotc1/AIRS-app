import Foundation
import AIRSCore
import EntitlementDiffCore

public enum BoundReviewError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let reason) = self { return "Bound review: \(reason)" }
        return nil
    }
}

// Reuse the existing bounded parser; keep numeric tokens and Unicode scalar bytes
// rather than Foundation's bool/number coercions or String's normalized equality.
indirect enum BoundJSONNode: Equatable, Sendable {
    case object([String:BoundJSONNode]), array([BoundJSONNode]), string(String), number(String), boolean(Bool), null
}

enum BoundJSON {
    static func parse(_ data: Data) throws -> BoundJSONNode {
        guard data.count <= InspectionArchive.maximumBytes else { throw InspectionArchiveError.limit }
        func convert(_ value: CoverageJSONIdentity) throws -> BoundJSONNode {
            switch value {
            case .object(let fields):
                var result: [String:BoundJSONNode] = [:]
                for (key,item) in fields {
                    guard let name = String(data:key,encoding:.utf8),result[name] == nil else { throw fail() }
                    result[name] = try convert(item)
                }
                return .object(result)
            case .array(let items): return .array(try items.map(convert))
            case .string(let bytes):
                guard let text = String(data:bytes,encoding:.utf8) else { throw fail() }; return .string(text)
            case .number(let text): return .number(text.hasPrefix("integer:") ? String(text.dropFirst(8)) : text)
            case .boolean(let flag): return .boolean(flag)
            case .null: return .null
            }
        }
        return try convert(CoverageJSONIdentity.parse(data))
    }
    static func fail(_ message: String = "Malformed or unsupported document.") -> BoundReviewError { .invalid(message) }
    static func object(_ node: BoundJSONNode, keys: Set<String>? = nil) throws -> [String:BoundJSONNode] {
        guard case .object(let value) = node, keys == nil || Set(value.keys) == keys else { throw fail() }
        return value
    }
    static func text(_ node: BoundJSONNode?, max: Int = 256) throws -> String {
        guard case .string(let value) = node, value.utf8.count <= max else { throw fail() }; return value
    }
    static func integer(_ node: BoundJSONNode?, positive: Bool = false) throws -> UInt64 {
        guard case .number(let token) = node, !token.isEmpty,
              token.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(token),
              !positive || value > 0 else { throw fail("Expected a bounded nonnegative integer, not a boolean or float.") }
        return value
    }
    static func uuid(_ node: BoundJSONNode?) throws -> UUID {
        guard let id = UUID(uuidString: try text(node)) else { throw fail() }; return id
    }
    static func digest(_ node: BoundJSONNode?) throws -> String {
        let value = try text(node)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw fail() }; return value
    }
    static func hex(_ node: BoundJSONNode?) throws -> UInt64 {
        let value = try text(node)
        guard value.hasPrefix("0x"), value.count > 2, value.utf8.count <= 18,
              value.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let number = UInt64(value.dropFirst(2),radix:16) else { throw fail() }; return number
    }
    static func equal(_ a: BoundJSONNode, _ b: BoundJSONNode) -> Bool {
        switch (a,b) {
        case (.string(let x),.string(let y)): return x.utf8.elementsEqual(y.utf8)
        case (.number(let x),.number(let y)):
            // Schema-constrained integers compare numerically; all other scalar
            // spellings remain exact, avoiding precision loss for 64-bit values.
            if let u = UInt64(x), let v = UInt64(y), !x.contains("."), !y.contains(".") { return u == v }
            return x == y
        case (.object(let x),.object(let y)):
            return x.count == y.count && x.allSatisfy { key,value in
                guard let actualKey = y.keys.first(where: { $0.utf8.elementsEqual(key.utf8) }), let other = y[actualKey] else { return false }
                return equal(value,other)
            }
        case (.array(let x),.array(let y)): return x.count == y.count && zip(x,y).allSatisfy(equal)
        case (.boolean(let x),.boolean(let y)): return x == y
        case (.null,.null): return true
        default: return false
        }
    }
    static func encode(_ value: BoundJSONNode) throws -> Data {
        func raw(_ value: BoundJSONNode) throws -> Any {
            switch value {
            case .object(let fields): return try fields.mapValues(raw)
            case .array(let items): return try items.map(raw)
            case .string(let text): return text
            case .number(let token):
                // Requests are a bounded integer-only projection of schema-1 data.
                guard let n = UInt64(token), !token.contains("."), !token.contains("e"), !token.contains("E") else { throw fail() }
                return NSNumber(value:n)
            case .boolean(let flag): return flag
            case .null: return NSNull()
            }
        }
        return try JSONSerialization.data(withJSONObject:raw(value),options:[.sortedKeys,.withoutEscapingSlashes])
    }
    static func strings(_ node: BoundJSONNode?, count: Int, bytes: Int) throws {
        guard case .array(let values) = node, values.count <= count else { throw fail("Receiver profile limit exceeded.") }
        for value in values { _ = try text(value,max:bytes) }
    }
}

public struct BoundReviewRequest: Sendable {
    public static let kind = "airs.macscope_bound_request"
    public static let profile = "exact_artifact_source_report_navigation_v1"
    public static let maximumRequestBytes = 1_048_576
    public let requestID: UUID
    public let findingID: String
    public let requestBytes: Data
    public let reportBytes: Data
    public let archiveBytes: Data
    public let requestDigest: String
    let root: [String:BoundJSONNode]
    var sourceDescriptor: BoundJSONNode { root["source_report"] ?? .null }
    var projection: [String:BoundJSONNode] { if case .object(let value) = root["projection"] { return value }; return [:] }

    private static let requirements = [
        "Verify architecture and selected-slice SHA-256 before applying an address to an open image.",
        "Use UUID as additional image identity when present; a matching filename is insufficient.",
        "Addresses are preferred unslid VM addresses; apply a verified runtime slide only in a runtime-aware adapter.",
        "This export defines a proposed adapter contract. It does not assume an existing MacScope GUI deep link or import command."]

    // Small native projection of bridge.make_handoff; audit parsing and all archive
    // machinery remain shared. A cross-language fixture check guards this seam.
    private static func source(_ bytes: Data, findingID: String) throws -> (BoundJSONNode,BoundJSONNode) {
        let root = try BoundJSON.object(BoundJSON.parse(bytes))
        guard try BoundJSON.integer(root["schema_version"]) == 1 else { throw BoundJSON.fail() }
        _ = try AuditReport.decode(bytes)
        guard case .array(let findings) = root["findings"] else { throw BoundJSON.fail() }
        let matching = try findings.filter { try BoundJSON.text(BoundJSON.object($0)["id"]) == findingID }
        guard matching.count == 1 else { throw BoundJSON.fail("Selected finding must occur exactly once.") }
        let finding = try BoundJSON.object(matching[0])
        let function = try BoundJSON.object(finding["function"] ?? .null)
        let image = try BoundJSON.object(root["image"] ?? .null)
        let generator = try BoundJSON.object(root["generator"] ?? .null)
        for key in ["name","version","analysis_model_version"] { _ = try BoundJSON.text(generator[key]) }
        let config: BoundJSONNode
        if let recorded = root["analysis_config"] {
            let value = try BoundJSON.object(recorded,keys:["limits"])
            let limits = try BoundJSON.object(value["limits"] ?? .null)
            for limit in limits.values { _ = try BoundJSON.integer(limit) }
            config = .object(["state":.string("recorded"),"value":recorded])
        } else { config = .object(["state":.string("not_recorded")]) }
        let relativeStart = try BoundJSON.hex(function["image_offset"])
        let size = try BoundJSON.integer(function["size"],positive:true)
        let (end,overflow) = relativeStart.addingReportingOverflow(size)
        guard !overflow, try BoundJSON.integer(image["slice_size"],positive:true) > 0,
              try BoundJSON.integer(image["cpu_subtype"]) <= UInt32.max else { throw BoundJSON.fail() }
        _ = try BoundJSON.integer(image["slice_offset"])
        for key in ["name"] { _ = try BoundJSON.text(function[key],max:65_536) }
        _ = try BoundJSON.text(image["display_name"],max:65_536)
        try BoundJSON.strings(finding["reason_codes"],count:4096,bytes:4096)
        try BoundJSON.strings(finding["checked_pcs"],count:4096,bytes:256)
        try BoundJSON.strings(finding["limitations"],count:256,bytes:4096)
        guard case .array(let evidence) = finding["evidence"], evidence.count <= 4096 else { throw BoundJSON.fail() }
        let start = try BoundJSON.hex(function["address"]), stop = try BoundJSON.hex(function["end_address"])
        for row in evidence {
            let entry = try BoundJSON.object(row)
            _ = try BoundJSON.text(entry["code"])
            _ = try BoundJSON.text(entry["message"],max:4096)
            if let address = entry["address"] { let pc = try BoundJSON.hex(address); guard pc >= start,pc < stop else { throw BoundJSON.fail() } }
            for key in ["expected","observed"] { if let v = entry[key] { _ = try BoundJSON.text(v,max:1_048_576) } }
        }
        let imageKeys = ["display_name","uuid","architecture","cpu_subtype","container_sha256","slice_sha256","slice_offset","slice_size","preferred_base"]
        let findingKeys = ["verdict","coverage","mode","scope","reason_codes","checked_pcs","evidence","limitations"]
        let projection: BoundJSONNode = .object([
            "schema_version":.number("1"),"report_kind":.string("airs.macscope_handoff"),"integration_status":.string("proposed_export_contract"),
            "image":.object(Dictionary(uniqueKeysWithValues:imageKeys.map { ($0,image[$0] ?? .null) })),
            "selection":.object(["finding_id":.string(findingID),"function_name":function["name"] ?? .null,
                "address_space":.string("preferred_vm"),"vm_range":.object(["start":function["address"] ?? .null,"end":function["end_address"] ?? .null]),
                "image_relative_range":.object(["start":function["image_offset"] ?? .null,"end":.string("0x"+String(end,radix:16))])]),
            "finding":.object(Dictionary(uniqueKeysWithValues:findingKeys.map { ($0,finding[$0] ?? .null) })),
            "source_analysis":.object(generator),"requirements":.array(requirements.map(BoundJSONNode.string))])
        guard try BoundJSON.encode(projection).count <= maximumRequestBytes else { throw BoundJSON.fail("Receiver profile limit exceeded.") }
        return (projection,config)
    }
    public static func create(report: Data, findingID: String) throws -> Self {
        guard report.count <= InspectionArchive.maximumBytes else { throw InspectionArchiveError.limit }
        let (projection,config) = try source(report,findingID:findingID)
        let attachment = EvidenceAttachment(id:UUID(),kind:"airs.audit",schemaVersion:1,mediaType:"application/json",
            sha256:AssessmentDocument.digest(report),byteCount:report.count,bytes:report)
        let id = UUID()
        let request: BoundJSONNode = .object(["report_kind":.string(kind),"schema_version":.number("1"),"request_id":.string(id.uuidString.lowercased()),
            "profile":.string(profile),"source_report":.object(["attachment_id":.string(attachment.id.uuidString.lowercased()),
                "sha256":.string(attachment.sha256),"byte_count":.number(String(report.count))]),
            "finding_id":.string(findingID),"configuration":config,"projection":projection])
        let payload = try BoundJSON.encode(request)
        guard payload.count <= maximumRequestBytes else { throw InspectionArchiveError.limit }
        let item = EvidenceAttachment(id:UUID(),kind:kind,schemaVersion:1,mediaType:"application/json",
            sha256:AssessmentDocument.digest(payload),byteCount:payload.count,bytes:payload)
        let archive = try InspectionArchive(attachments:[item,attachment]).encode()
        return Self(requestID:id,findingID:findingID,requestBytes:payload,reportBytes:report,archiveBytes:archive,
            requestDigest:item.sha256,root:try BoundJSON.object(request))
    }
    public static func decodeArchive(_ data: Data) throws -> Self {
        let archive = try InspectionArchive.decode(data)
        guard archive.attachments.count == 2, archive.components.isEmpty,
              let item = archive.attachments.first(where:{$0.kind == kind}),item.schemaVersion == 1,item.mediaType == "application/json",
              item.bytes.count <= maximumRequestBytes,
              let report = archive.attachments.first(where:{$0.kind == "airs.audit"}),report.schemaVersion == 1,report.mediaType == "application/json" else { throw BoundJSON.fail() }
        let root = try BoundJSON.object(BoundJSON.parse(item.bytes),keys:["report_kind","schema_version","request_id","profile","source_report","finding_id","configuration","projection"])
        guard try BoundJSON.text(root["report_kind"]) == kind, try BoundJSON.integer(root["schema_version"]) == 1,
              try BoundJSON.text(root["profile"]) == profile else { throw BoundJSON.fail() }
        let id = try BoundJSON.uuid(root["request_id"]), finding = try BoundJSON.text(root["finding_id"])
        let descriptor = try BoundJSON.object(root["source_report"] ?? .null,keys:["attachment_id","sha256","byte_count"])
        guard try BoundJSON.uuid(descriptor["attachment_id"]) == report.id,
              try BoundJSON.digest(descriptor["sha256"]) == report.sha256,
              try BoundJSON.integer(descriptor["byte_count"]) == report.byteCount else { throw BoundJSON.fail("Source report identity mismatch.") }
        let (projection,config) = try source(report.bytes,findingID:finding)
        guard BoundJSON.equal(root["configuration"] ?? .null,config),BoundJSON.equal(root["projection"] ?? .null,projection) else { throw BoundJSON.fail("Configuration or finding projection mismatch.") }
        return Self(requestID:id,findingID:finding,requestBytes:item.bytes,reportBytes:report.bytes,archiveBytes:data,
            requestDigest:item.sha256,root:root)
    }
}
