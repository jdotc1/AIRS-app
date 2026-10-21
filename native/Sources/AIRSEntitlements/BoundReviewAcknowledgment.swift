import Foundation
import AIRSCore
import EntitlementDiffCore

/// Imported issuer claims, not a live MacScope observation or signed attestation.
public struct BoundReviewAcknowledgment: Sendable {
    public static let kind = "airs.macscope_bound_acknowledgment"
    public let id: UUID
    public let requestID: UUID?
    public let outcome: String
    public let code: String
    public let bytes: Data
    private let root: [String:BoundJSONNode]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw InspectionArchiveError.limit }
        let r = try BoundJSON.object(BoundJSON.parse(data),keys:["report_kind","schema_version","acknowledgment_id","request","untrusted_request_id","source_report","finding_id","consumer","profile","completed_at","outcome","code","admission","destination","navigation","semantics","diagnostic"])
        guard try BoundJSON.text(r["report_kind"]) == kind,try BoundJSON.integer(r["schema_version"]) == 1,
              try BoundJSON.text(r["semantics"]) == "source_reported_not_consumer_verified" else { throw BoundJSON.fail() }
        let id = try BoundJSON.uuid(r["acknowledgment_id"])
        _ = try BoundJSON.text(r["diagnostic"],max:4096)
        let completed = try BoundJSON.text(r["completed_at"],max:64)
        guard completed.range(of:#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#,options:.regularExpression) != nil else { throw BoundJSON.fail() }
        let clock = ISO8601DateFormatter()
        clock.formatOptions = completed.contains(".") ? [.withInternetDateTime,.withFractionalSeconds] : [.withInternetDateTime]
        guard clock.date(from:completed) != nil else { throw BoundJSON.fail() }
        let consumer = try BoundJSON.object(r["consumer"] ?? .null,keys:["bundle_id","version","build","source_revision","build_provenance_state"])
        for key in ["bundle_id","version","build"] { guard try !BoundJSON.text(consumer[key]).isEmpty else { throw BoundJSON.fail() } }
        switch try BoundJSON.text(consumer["build_provenance_state"]) {
        case "declared":
            let revision = try BoundJSON.text(consumer["source_revision"])
            guard revision.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil else { throw BoundJSON.fail() }
        case "unavailable": guard consumer["source_revision"] == .null else { throw BoundJSON.fail() }
        default: throw BoundJSON.fail()
        }
        if r["untrusted_request_id"] != .null { _ = try BoundJSON.uuid(r["untrusted_request_id"]) }
        if r["profile"] != .null { guard try BoundJSON.text(r["profile"]) == BoundReviewRequest.profile else { throw BoundJSON.fail() } }
        let requestID: UUID?
        if r["request"] == .null {
            requestID = nil
            guard r["source_report"] == .null,r["finding_id"] == .null else { throw BoundJSON.fail() }
        } else {
            let request = try BoundJSON.object(r["request"] ?? .null,keys:["request_id","sha256","byte_count"])
            requestID = try BoundJSON.uuid(request["request_id"])
            _ = try BoundJSON.digest(request["sha256"])
            guard try BoundJSON.integer(request["byte_count"],positive:true) <= BoundReviewRequest.maximumRequestBytes else { throw BoundJSON.fail() }
            let source = try BoundJSON.object(r["source_report"] ?? .null,keys:["attachment_id","sha256","byte_count"])
            _ = try BoundJSON.uuid(source["attachment_id"]); _ = try BoundJSON.digest(source["sha256"])
            guard try BoundJSON.integer(source["byte_count"],positive:true) <= InspectionArchive.maximumBytes,
                  try BoundJSON.text(r["finding_id"]).range(of:"^airsf-[0-9a-f]{64}$",options:.regularExpression) != nil,
                  r["profile"] == .string(BoundReviewRequest.profile),r["untrusted_request_id"] == .null else { throw BoundJSON.fail() }
        }
        let outcome = try BoundJSON.text(r["outcome"]), code = try BoundJSON.text(r["code"]), admission = try BoundJSON.text(r["admission"])
        switch admission {
        case "not_validated": guard requestID == nil,r["destination"] == .null else { throw BoundJSON.fail() }
        case "source_bound": guard requestID != nil,r["destination"] == .null else { throw BoundJSON.fail() }
        case "destination_verified":
            guard requestID != nil else { throw BoundJSON.fail() }
            try validateDestination(r["destination"] ?? .null)
        default: throw BoundJSON.fail()
        }
        let rejections: Set<String> = ["malformed_transport","attachment_identity_mismatch","unsupported_contract","profile_limit","invalid_source_report","unsupported_configuration","finding_not_unique","configuration_mismatch","projection_mismatch","identity_unavailable","image_identity_mismatch","address_mapping_mismatch","stale_destination"]
        switch outcome {
        case "navigated":
            guard code == "navigation_completed",admission == "destination_verified" else { throw BoundJSON.fail() }
            let navigation = try BoundJSON.object(r["navigation"] ?? .null,keys:["requested_start","selected_start","selected_image_id"])
            let destination = try BoundJSON.object(r["destination"] ?? .null)
            guard try BoundJSON.hex(navigation["requested_start"]) == BoundJSON.hex(navigation["selected_start"]),
                  try BoundJSON.uuid(navigation["selected_image_id"]) == BoundJSON.uuid(destination["image_id"]) else { throw BoundJSON.fail("Navigation readback does not match its request.") }
        case "cancelled": guard code == "user_cancelled",admission == "destination_verified",r["navigation"] == .null else { throw BoundJSON.fail() }
        case "rejected":
            guard rejections.contains(code),r["navigation"] == .null else { throw BoundJSON.fail() }
            let destinationFailures: Set<String> = ["identity_unavailable","image_identity_mismatch","address_mapping_mismatch","stale_destination"]
            guard admission == (destinationFailures.contains(code) ? "source_bound" : "not_validated") else { throw BoundJSON.fail() }
        case "error":
            guard ["read_failed","navigation_failed"].contains(code),r["navigation"] == .null,
                  admission == (code == "read_failed" ? "not_validated" : "destination_verified") else { throw BoundJSON.fail() }
        default: throw BoundJSON.fail()
        }
        return Self(id:id,requestID:requestID,outcome:outcome,code:code,bytes:data,root:r)
    }
    private static func validateDestination(_ value: BoundJSONNode) throws {
        let d = try BoundJSON.object(value,keys:["image_id","uuid","architecture","cpu_subtype","container_sha256","slice_sha256","slice_offset","slice_size","preferred_base"])
        _ = try BoundJSON.uuid(d["image_id"])
        if d["uuid"] != .null { _ = try BoundJSON.uuid(d["uuid"]) }
        guard try ["arm64","arm64e"].contains(BoundJSON.text(d["architecture"])),
              try BoundJSON.integer(d["cpu_subtype"]) <= UInt32.max else { throw BoundJSON.fail() }
        _ = try BoundJSON.digest(d["container_sha256"]); _ = try BoundJSON.digest(d["slice_sha256"])
        _ = try BoundJSON.integer(d["slice_offset"]); _ = try BoundJSON.integer(d["slice_size"],positive:true)
        _ = try BoundJSON.hex(d["preferred_base"])
    }
    public func matches(_ request: BoundReviewRequest) throws -> Bool {
        guard requestID == request.requestID else { return false }
        let descriptor = try BoundJSON.object(root["request"] ?? .null)
        guard try BoundJSON.digest(descriptor["sha256"]) == request.requestDigest,
              try BoundJSON.integer(descriptor["byte_count"]) == request.requestBytes.count,
              BoundJSON.equal(root["source_report"] ?? .null,request.sourceDescriptor),
              try BoundJSON.text(root["finding_id"]) == request.findingID else { return false }
        if root["destination"] != .null {
            let actual = try BoundJSON.object(root["destination"] ?? .null)
            let expected = try BoundJSON.object(request.projection["image"] ?? .null)
            for key in ["architecture","cpu_subtype","container_sha256","slice_sha256","slice_offset","slice_size"] {
                guard BoundJSON.equal(actual[key] ?? .null,expected[key] ?? .null) else { throw BoundJSON.fail("Receipt destination differs from the bound source image.") }
            }
            guard try BoundJSON.hex(actual["preferred_base"]) == BoundJSON.hex(expected["preferred_base"]) else { throw BoundJSON.fail() }
            if expected["uuid"] != .null {
                guard try BoundJSON.uuid(actual["uuid"]) == BoundJSON.uuid(expected["uuid"]) else { throw BoundJSON.fail() }
            }
        }
        if outcome == "navigated" {
            let selection = try BoundJSON.object(request.projection["selection"] ?? .null)
            let range = try BoundJSON.object(selection["vm_range"] ?? .null)
            let navigation = try BoundJSON.object(root["navigation"] ?? .null)
            guard try BoundJSON.hex(range["start"]) == BoundJSON.hex(navigation["requested_start"]) else { throw BoundJSON.fail("Receipt navigation differs from the bound finding.") }
        }
        return true
    }
}
