import Foundation
import AIRSCore
import EntitlementDiffCore

/// Decoder for src/airs/coverage.py, not a second analyzer or deduplicator.
public struct CoverageInventory:Decodable,Sendable {
    public struct Summary:Decodable,Sendable {
        public let duplicate_report_count:Int
        public let function_count:Int
        public let agreement_count:Int
        public let inconsistency_count:Int
        public let unresolved_count:Int
        public let input_report_count:Int
        public let unique_image_model_config_count:Int
        public let conflicting_report_count:Int
    }
    public struct Record:Decodable,Identifiable,Sendable {
        public var id:Int {index}
        public let index:Int
        public let image:Image
        public let model:String
        public let summary:ReportSummary
        public let duplicate_of:Int?
    }
    public struct Image:Decodable,Sendable {
        public let display_name:String
        public let slice_sha256:String
        public let architecture:String
        public let cpu_subtype:Int
        public let uuid:String?
    }
    public struct Reason:Decodable,Identifiable,Sendable {
        public var id:String {Data(reason.utf8).base64EncodedString()}
        public let reason:String
        public let count:Int
        public let examples:[Example]
    }
    public struct Example:Decodable,Identifiable,Sendable {
        public var id:String {String(report_index)+":"+finding_id}
        public let report_index:Int
        public let finding_id:String
        public let function_name:String?
        /// Function-entry preferred VM, not a checked-PC observation claim.
        public let pc:String
        public let scope:String
        public let mode:String
    }
    public let schema_version:Int
    public let report_kind:String
    public let status:String
    public let summary:Summary
    public let reports:[Record]
    public let conflicting_report_indices:[Int]
    public let models:[String:Int]
    public let reasons:[Reason]
    public let limitations:[String]
    private var configurationIdentities:[CoverageJSONIdentity]=[]
    private enum CodingKeys:String,CodingKey {case schema_version,report_kind,status,summary,reports,conflicting_report_indices,models,reasons,limitations}
    public struct VerdictRatio:Sendable {
        public let resolvedNumerator:Int
        public let functionDenominator:Int
    }
    /// This ratio concerns verdict counts only. Never combine different models,
    /// configurations, CPU scopes, unknown configurations or conflicting variants.
    public var compatibleVerdictRatio:VerdictRatio? {
        let inputs=reports.filter{$0.duplicate_of == nil}
        guard status == "complete",let first=inputs.first,configurationIdentities.count == reports.count,configurationIdentities[first.index] != .null,summary.function_count > 0,
              inputs.allSatisfy({$0.model.utf8.elementsEqual(first.model.utf8) && configurationIdentities[$0.index] == configurationIdentities[first.index] && $0.image.architecture == first.image.architecture && $0.image.cpu_subtype == first.image.cpu_subtype}) else {return nil}
        return .init(resolvedNumerator:summary.agreement_count+summary.inconsistency_count,functionDenominator:summary.function_count)
    }
    public func configurationLabel(for record:Record)->String {
        guard configurationIdentities.indices.contains(record.index),configurationIdentities[record.index] != .null else {return "Configuration not recorded"}
        let first=configurationIdentities.firstIndex(of:configurationIdentities[record.index]) ?? record.index
        return "Configuration identity group \(first + 1)"
    }
    public static func decode(_ bytes:Data) throws -> Self {
        guard bytes.count <= 32*1_048_576 else {throw InspectionArchiveError.limit}
        let root=try CoverageJSONIdentity.parse(bytes)
        guard case .object(let fields)=root,Set(fields.keys) == Set(["schema_version","report_kind","status","summary","reports","conflicting_report_indices","models","reasons","limitations"].map{Data($0.utf8)}) else {throw InspectionArchiveError.invalid}
        var value=try JSONDecoder().decode(Self.self,from:bytes)
        guard let records=root["reports"]?.array else {throw InspectionArchiveError.invalid}
        value.configurationIdentities=records.map{$0["analysis_config"] ?? .null}
        try value.validate();return value
    }
    private func validate() throws {
        func nonnegative(_ s:ReportSummary)->Bool {
            [s.functionCount,s.agreementCount,s.inconsistencyCount,s.unresolvedCount,s.metadataEntryCount,s.checkedPCCount].allSatisfy{$0 >= 0 && $0 <= 10_000_000} && s.functionCount <= 50_000 && s.agreementCount+s.inconsistencyCount+s.unresolvedCount == s.functionCount
        }
        guard schema_version == 1,report_kind == "airs.coverage_inventory",["complete","conflicting_reports"].contains(status),reports.count <= 128,configurationIdentities.count == reports.count,reasons.count <= 4096,models.count <= 128,limitations.count <= 64,
              summary.input_report_count == reports.count,summary.function_count >= 0,summary.function_count <= 200_000,
              [summary.agreement_count,summary.inconsistency_count,summary.unresolved_count,summary.duplicate_report_count,summary.unique_image_model_config_count,summary.conflicting_report_count].allSatisfy({$0 >= 0 && $0 <= 200_000}),
              summary.agreement_count+summary.inconsistency_count+summary.unresolved_count == summary.function_count,
              limitations.allSatisfy({$0.utf8.count <= 16_384}) else {throw InspectionArchiveError.invalid}
        var groups:[[Record]]=[],modelCounts:[String:Int]=[:],totals=[0,0,0,0],duplicates=0,inputFindings=0
        func sameKey(_ a:Record,_ b:Record)->Bool {
            a.image.slice_sha256 == b.image.slice_sha256 && a.image.architecture == b.image.architecture && a.image.cpu_subtype == b.image.cpu_subtype && a.model.utf8.elementsEqual(b.model.utf8) && configurationIdentities[a.index] == configurationIdentities[b.index]
        }
        for (index,r) in reports.enumerated() {
            guard r.index == index,ReviewPolicy.validDigest(r.image.slice_sha256),["arm64","arm64e"].contains(r.image.architecture),r.image.cpu_subtype >= 0,
                  r.image.uuid.map({UUID(uuidString:$0) != nil}) ?? true,!r.model.isEmpty,r.model.utf8.count <= 256,r.image.display_name.utf8.count <= 4096,nonnegative(r.summary) else {throw InspectionArchiveError.invalid}
            inputFindings += r.summary.functionCount
            guard inputFindings <= 200_000 else {throw InspectionArchiveError.limit}
            if let earlier=r.duplicate_of {
                guard earlier >= 0,earlier < index,reports[earlier].duplicate_of == nil,sameKey(r,reports[earlier]),
                      r.summary.functionCount == reports[earlier].summary.functionCount,r.summary.agreementCount == reports[earlier].summary.agreementCount,
                      r.summary.inconsistencyCount == reports[earlier].summary.inconsistencyCount,r.summary.unresolvedCount == reports[earlier].summary.unresolvedCount,
                      r.summary.checkedPCCount == reports[earlier].summary.checkedPCCount,r.summary.metadataEntryCount == reports[earlier].summary.metadataEntryCount else {throw InspectionArchiveError.invalid}
                duplicates += 1;continue
            }
            if let group=groups.firstIndex(where:{$0.first.map{sameKey($0,r)} ?? false}) {groups[group].append(r)} else {groups.append([r])}
            modelCounts[r.model,default:0] += 1
            totals[0] += r.summary.functionCount;totals[1] += r.summary.agreementCount;totals[2] += r.summary.inconsistencyCount;totals[3] += r.summary.unresolvedCount
        }
        let conflicts=groups.filter{$0.count > 1}.flatMap{$0.map(\.index)}.sorted()
        guard conflicts == conflicting_report_indices,summary.conflicting_report_count == conflicts.count,status == (conflicts.isEmpty ? "complete":"conflicting_reports"),summary.duplicate_report_count == duplicates,summary.unique_image_model_config_count == groups.count,models == modelCounts,
              totals == [summary.function_count,summary.agreement_count,summary.inconsistency_count,summary.unresolved_count],
              Set(reasons.map{Data($0.reason.utf8)}).count == reasons.count else {throw InspectionArchiveError.invalid}
        for reason in reasons {
            guard !reason.reason.isEmpty,reason.reason.utf8.count <= 4096,reason.count > 0,reason.count <= summary.unresolved_count,!reason.examples.isEmpty,reason.examples.count <= min(8,reason.count),Set(reason.examples.map(\.id)).count == reason.examples.count else {throw InspectionArchiveError.invalid}
            for e in reason.examples {
                guard reports.indices.contains(e.report_index),reports[e.report_index].duplicate_of == nil,e.finding_id.hasPrefix("airsf-"),ReviewPolicy.validDigest(String(e.finding_id.dropFirst(6))),e.pc.hasPrefix("0x"),e.pc.count <= 18,UInt64(e.pc.dropFirst(2),radix:16) != nil,
                      ["synchronous_call_sites","modeled_leaf_body","metadata_only"].contains(e.scope),["frame","frameless","dwarf","pauth_frame","none","unknown"].contains(e.mode),(e.function_name?.utf8.count ?? 0) <= 4096 else {throw InspectionArchiveError.invalid}
            }
        }
    }
    /// Resolve only a user-selected saved report; no path inference or live read.
    /// The inventory has no original-report digest, so this proves a matching
    /// referenced observation, not the original file's byte identity.
    public func resolve(_ example:Example,reason:String,sourceBytes:Data) throws -> (AuditReport,Finding) {
        guard let category=reasons.first(where:{$0.reason.utf8.elementsEqual(reason.utf8)}),let example=category.examples.first(where:{$0.id == example.id}),reports.indices.contains(example.report_index),configurationIdentities.count == reports.count else {throw InspectionArchiveError.invalid}
        let record=reports[example.report_index],report=try AuditReport.decode(sourceBytes)
        let config=try CoverageJSONIdentity.parse(sourceBytes)["analysis_config"] ?? .null
        guard report.image.sliceSHA256 == record.image.slice_sha256,report.image.architecture == record.image.architecture,report.image.cpuSubtype == record.image.cpu_subtype,report.image.uuid == record.image.uuid,
              report.generator.analysisModelVersion.utf8.elementsEqual(record.model.utf8),config == configurationIdentities[record.index],
              report.summary.functionCount == record.summary.functionCount,report.summary.agreementCount == record.summary.agreementCount,report.summary.inconsistencyCount == record.summary.inconsistencyCount,report.summary.unresolvedCount == record.summary.unresolvedCount,report.summary.metadataEntryCount == record.summary.metadataEntryCount,report.summary.checkedPCCount == record.summary.checkedPCCount,
              let finding=report.findings.first(where:{$0.id == example.finding_id}),finding.verdict == .unresolved,finding.function.address == example.pc,finding.function.name.map{Data($0.utf8)} == example.function_name.map{Data($0.utf8)},finding.scope == example.scope,finding.mode == example.mode,finding.reasonCodes.contains(where:{$0.utf8.elementsEqual(reason.utf8)}) else {throw InspectionArchiveError.invalid}
        return (report,finding)
    }
}
