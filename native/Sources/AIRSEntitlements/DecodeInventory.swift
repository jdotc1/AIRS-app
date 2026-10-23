import Foundation
import AIRSCore

/// Saved decode-only observations. Import never invokes the decoder or an audit.
public struct DecodeInventory: Decodable, Sendable {
    public struct Image: Decodable, Sendable {
        public let display_name, container_sha256, slice_sha256, architecture: String
        public let cpu_subtype, slice_offset, slice_size, file_type: Int
        public let uuid: String?
        public let preferred_base: String
    }
    public struct Summary: Decodable, Sendable {
        public let function_count, fully_scanned_function_count, observed_word_count: Int
        public let decoder_admitted_word_count, decline_count, retained_blocker_count, omitted_decline_count: Int
    }
    public struct Blocker: Decodable, Identifiable, Sendable {
        public var id: String { address }
        public let address, word, reason, message: String
    }
    public struct Function: Decodable, Sendable {
        public let name: String?
        public let address, end_address, image_offset, boundary_source: String
        public let size: Int
    }
    public struct Row: Decodable, Identifiable, Sendable {
        public var id: String { function.address }
        public let function: Function
        public let scan_status: String
        public let word_scan_complete, blockers_complete: Bool
        public let observed_word_count, decoder_admitted_word_count, decline_count, omitted_decline_count: Int
        public let blockers: [Blocker]
    }
    public struct Reason: Decodable, Identifiable, Sendable {
        public var id: String { reason }
        public let reason: String
        public let observed_count: Int
    }
    public struct Issue: Decodable, Sendable {
        public let code, message: String
        public let offset: Int?
    }
    public struct Configuration: Decodable, Sendable { public let limits: [String:Int] }
    public let schema_version: Int
    public let report_kind, decoder_model, status, address_space: String
    public let analysis_config: Configuration
    public let image: Image
    public let summary: Summary
    public let functions: [Row]
    public let reasons: [Reason]
    public let issues: [Issue]
    public let limitations: [String]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1_048_576 else { throw InspectionArchiveError.limit }
        let root = try CoverageJSONIdentity.parse(data)
        guard case .object(let fields) = root,
              Set(fields.keys) == Set(["schema_version","report_kind","decoder_model","status","address_space","analysis_config","image","summary","reasons","functions","issues","limitations"].map { Data($0.utf8) }) else { throw InspectionArchiveError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    /// Link a user-selected saved audit by recorded identity and exact function.
    /// Decode limits and audit limits remain independent; no result is inferred.
    public func resolveFunction(_ rowID:String,sourceBytes:Data) throws -> (AuditReport,Finding) {
        guard image.slice_offset >= 0,image.slice_size >= 0,let row=functions.first(where:{$0.id == rowID}),row.function.size > 0,
              row.scan_status != "invalid_extent" else {
            throw ReportError.invalidContents("The selected inventory row has no usable function extent.")
        }
        guard sourceBytes.count <= ReportFiles.maximumBytes else {throw ReportError.tooLarge(ReportFiles.maximumBytes)}
        _ = try CoverageJSONIdentity.parse(sourceBytes)
        let report=try AuditReport.decode(sourceBytes)
        func vm(_ text:String)->UInt64? {UInt64(text.dropFirst(2),radix:16)}
        guard report.image.containerSHA256 == image.container_sha256,
              report.image.sliceSHA256 == image.slice_sha256,
              report.image.architecture == image.architecture,report.image.cpuSubtype == image.cpu_subtype,
              report.image.fileType == [2:"execute",6:"dylib",8:"bundle"][image.file_type],
              report.image.uuid == image.uuid,report.image.sliceOffset == UInt64(image.slice_offset),
              report.image.sliceSize == UInt64(image.slice_size),vm(report.image.preferredBase) == vm(image.preferred_base),
              report.generator.analysisModelVersion.utf8.elementsEqual(decoder_model.utf8) else {
            throw ReportError.invalidContents("The saved audit does not match this inventory's recorded image, slice and model identity.")
        }
        let fn=row.function
        let matches=report.findings.filter {
            vm($0.function.address) == vm(fn.address) && vm($0.function.endAddress) == vm(fn.end_address)
                && vm($0.function.imageOffset) == vm(fn.image_offset) && $0.function.size == UInt64(fn.size)
                && $0.function.boundarySource.utf8.elementsEqual(fn.boundary_source.utf8)
                && $0.function.name.map {Data($0.utf8)} == fn.name.map {Data($0.utf8)}
        }
        guard matches.count == 1,let finding=matches.first else {
            throw ReportError.invalidContents("The saved audit has no unique exact function match. The inventory remains open.")
        }
        return (report,finding)
    }

    private func validate() throws {
        func require(_ condition: Bool) throws { if !condition { throw InspectionArchiveError.invalid } }
        func text(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 16_384 }
        func address(_ value: String) throws -> UInt64 {
            guard value.hasPrefix("0x"), value.count <= 18,
                  let result = UInt64(value.dropFirst(2), radix:16) else { throw InspectionArchiveError.invalid }
            return result
        }
        try require(schema_version == 1 && report_kind == "airs.decode_inventory" && address_space == "preferred_vm")
        try require(text(decoder_model) && ["complete","partial","no_functions"].contains(status))
        try require(functions.count <= 1024 && reasons.count <= 4096 && issues.count <= 4096 && limitations.count <= 64)
        try require(ReviewPolicy.validDigest(image.container_sha256) && ReviewPolicy.validDigest(image.slice_sha256))
        try require(text(image.display_name) && ["arm64","arm64e"].contains(image.architecture) && image.cpu_subtype >= 0 && image.cpu_subtype <= Int(UInt32.max))
        try require(image.slice_offset >= 0 && image.slice_size >= 0 && image.slice_size <= Int.max - image.slice_offset && image.file_type >= 0)
        try require(image.uuid.map { UUID(uuidString:$0) != nil } ?? true)
        let base = try address(image.preferred_base)
        let limits = analysis_config.limits
        try require(limits.count <= 64 && limits.values.allSatisfy { $0 >= 0 && $0 <= 1_073_741_824 })
        guard let perWords = limits["max_instructions_per_function"], let totalWords = limits["max_total_instructions"],
              let perDetails = limits["max_evidence_per_function"], let totalDetails = limits["max_total_evidence"],
              let maxFunctions = limits["max_functions"] else { throw InspectionArchiveError.invalid }
        try require(functions.count <= maxFunctions && totalWords <= 1_000_000 && totalDetails <= 4096)
        var observed = 0, admitted = 0, declined = 0, retained = 0, omitted = 0, scanned = 0
        var previousEnd: UInt64 = 0, previousStart: UInt64?, reasonTotals: [String:Int] = [:], detailReasons: [String:Int] = [:]
        let statuses = ["complete","excluded_architecture","excluded_boundary","invalid_extent","partial_total_budget","partial_function_budget","unmapped_bytes"]
        for row in functions {
            let fn = row.function, start = try address(fn.address), end = try address(fn.end_address)
            let offset = try address(fn.image_offset)
            let distance = end >= start ? end-start : start-end
            try require(distance <= UInt64(Int.max))
            let expectedSize = end >= start ? Int(distance) : -Int(distance)
            try require(start >= base && start >= previousEnd && previousStart != start && fn.size == expectedSize && offset == start-base)
            if row.scan_status != "invalid_extent" { try require(end > start) }
            previousEnd = max(start,end); previousStart = start
            try require(fn.name.map { $0.utf8.count <= 16_384 } ?? true)
            try require(text(fn.boundary_source) && statuses.contains(row.scan_status))
            let counts = [row.observed_word_count,row.decoder_admitted_word_count,row.decline_count,row.omitted_decline_count]
            try require(counts.allSatisfy { $0 >= 0 && $0 <= 1_000_000 })
            try require(row.observed_word_count <= perWords && row.observed_word_count <= max(0,fn.size/4) && row.blockers.count <= perDetails)
            try require(row.decoder_admitted_word_count + row.decline_count == row.observed_word_count && row.blockers.count + row.omitted_decline_count == row.decline_count)
            let eligible = image.architecture == "arm64" && [0,1].contains(image.cpu_subtype) && fn.boundary_source == "lc_function_starts" && start%4 == 0 && fn.size > 0 && fn.size%4 == 0
            if row.word_scan_complete { try require(eligible && row.scan_status == "complete" && row.observed_word_count == fn.size/4) }
            try require(row.blockers_complete == (row.word_scan_complete && row.omitted_decline_count == 0))
            if row.scan_status == "complete" { try require(row.word_scan_complete) }
            if row.scan_status.hasPrefix("excluded_") || row.scan_status == "invalid_extent" || row.scan_status == "unmapped_bytes" {
                try require(row.observed_word_count == 0 && !row.word_scan_complete)
            }
            if row.observed_word_count > 0 { try require(eligible) }
            var previousPC: UInt64?
            for blocker in row.blockers {
                let pc = try address(blocker.address)
                try require(pc >= start && (pc-start)%4 == 0 && (pc-start)/4 < UInt64(row.observed_word_count) && (previousPC.map { pc > $0 } ?? true))
                try require(blocker.word.count == 10 && blocker.word.hasPrefix("0x") && UInt32(blocker.word.dropFirst(2),radix:16) != nil && text(blocker.reason) && text(blocker.message))
                previousPC = pc
                detailReasons[blocker.reason, default:0] += 1
            }
            observed += row.observed_word_count; admitted += row.decoder_admitted_word_count; declined += row.decline_count
            retained += row.blockers.count; omitted += row.omitted_decline_count; scanned += row.word_scan_complete ? 1 : 0
        }
        for reason in reasons {
            try require(text(reason.reason) && reason.observed_count > 0 && reason.observed_count <= declined && reasonTotals[reason.reason] == nil)
            reasonTotals[reason.reason] = reason.observed_count
        }
        try require(reasonTotals.values.reduce(0,+) == declined && detailReasons.allSatisfy { (reasonTotals[$0.key] ?? 0) >= $0.value })
        try require(observed <= totalWords && retained <= totalDetails)
        try require(summary.function_count == functions.count && summary.fully_scanned_function_count == scanned && summary.observed_word_count == observed && summary.decoder_admitted_word_count == admitted && summary.decline_count == declined && summary.retained_blocker_count == retained && summary.omitted_decline_count == omitted)
        try require(issues.allSatisfy { text($0.code) && text($0.message) && ($0.offset.map { $0 >= 0 } ?? true) } && limitations.allSatisfy(text))
        let expected = functions.isEmpty ? "no_functions" : functions.allSatisfy(\.blockers_complete) && issues.isEmpty ? "complete" : "partial"
        try require(status == expected)
    }
}
