import Foundation
import EntitlementDiffCore

/// Terminal adapter over the accepted detached companion APIs. Never restores a queue.
public enum PortableSettledProjectCommand {
    public static let usage = """
    airs-entitlements project-outcomes inspect --companion DIRECTORY
    airs-entitlements project-outcomes export --package PROJECT.airsproject --history-store HISTORY --output NEW_DIRECTORY --confirm-original-evidence
    airs-entitlements project-outcomes reconstruct --companion DIRECTORY --output NEW_STORE
    airs-entitlements project-outcomes reexport --package PROJECT.airsproject --recipient-store STORE --output NEW_DIRECTORY --confirm-original-evidence

    Use explicit absolute local paths and absent output directories. Export includes
    original project evidence, notes and recorded outcome messages verbatim; these
    may contain sensitive strings or paths. Select the source history store explicitly.
    Re-export requires an exact ordinary package snapshot matching the recipient's
    stored project and detached history. No app, executable, checkpoint or comparison
    report is transported or executed. Imported outcomes are historical, not live
    queue state. Audit outcomes remain unsupported. Recorded IDs do not authenticate
    original library provenance. Ordinary project commands are unchanged.
    """

    public static func run(arguments:[String]) async throws -> Data {
        guard let operation=arguments.first else {throw BoundReviewError.invalid(usage)}
        var values:[String:String]=[:],confirmed=false,index=1
        while index < arguments.count {
            let key=arguments[index]
            if key == "--confirm-original-evidence" {
                guard !confirmed else {throw BoundReviewError.invalid(usage)}
                confirmed=true;index += 1;continue
            }
            guard ["--package","--history-store","--recipient-store","--companion","--output"].contains(key),
                  values[key] == nil,index+1 < arguments.count,!arguments[index+1].hasPrefix("--") else {
                throw BoundReviewError.invalid(usage)
            }
            values[key]=arguments[index+1];index += 2
        }
        func require(_ keys:Set<String>,confirmation:Bool=false) throws {
            guard Set(values.keys) == keys,confirmed == confirmation else {throw BoundReviewError.invalid(usage)}
        }
        func path(_ key:String) throws -> URL {
            guard let value=values[key],value.hasPrefix("/") else {
                throw BoundReviewError.invalid("Use explicit absolute local paths.\n"+usage)
            }
            return URL(fileURLWithPath:value)
        }
        func output(_ object:[String:Any]) throws -> Data {
            var bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.prettyPrinted])
            bytes.append(10);return bytes
        }
        try Task.checkCancellation()
        switch operation {
        case "inspect":
            try require(["--companion"])
            let admission=try PortableSettledBatchProject.prepare(at:path("--companion"))
            return try output(summary(project:admission.project.project,history:admission.history))
        case "export":
            try require(["--package","--history-store","--output"],confirmation:true)
            let package=try path("--package"),historyRoot=try path("--history-store"),target=try path("--output")
            try ReportDestination.validate(target,excluding:[package,historyRoot])
            let admission=try PortableProjectReader.prepare(at:package)
            let history=try await PortableSettledBatchEvidence.prepare(project:admission.project,history:EntitlementBatchHistory(root:historyRoot))
            try Task.checkCancellation()
            try PortableSettledBatchProject.write(admission,history:history,to:target)
            var result=summary(project:admission.project,history:history);result["written"]=target.path
            return try output(result)
        case "reconstruct":
            try require(["--companion","--output"])
            let source=try path("--companion"),target=try path("--output")
            try ReportDestination.validate(target,excluding:[source])
            let admission=try PortableSettledBatchProject.prepare(at:source)
            _=try await PortableSettledBatchProject.reconstruct(admission,to:target)
            var result=summary(project:admission.project.project,history:admission.history);result["store"]=target.path
            return try output(result)
        case "reexport":
            try require(["--package","--recipient-store","--output"],confirmation:true)
            let package=try path("--package"),recipient=try path("--recipient-store"),target=try path("--output")
            try ReportDestination.validate(target,excluding:[package,recipient])
            let admission=try PortableProjectReader.prepare(at:package)
            let prepared=try PortableSettledBatchReexport.prepare(project:admission,recipientStore:recipient)
            try prepared.write(to:target)
            var result=summary(project:admission.project,history:prepared.history);result["written"]=target.path
            return try output(result)
        default:throw BoundReviewError.invalid(usage)
        }
    }

    private static func summary(project:InspectionProject,history:PortableSettledBatchEvidence)->[String:Any] {
        ["projectID":project.id.uuidString,"revision":project.revision,"name":project.name,
         "historicalOnly":true,"queueRestored":false,"comparisonReportsIncluded":false,
         "originalBinariesIncluded":false,"libraryProvenanceAuthenticated":false,
         "provenanceLimit":"Recorded IDs do not authenticate original library provenance; audit outcomes remain unsupported.",
         "outcomes":history.outcomes.map { outcome -> [String:Any] in
             var item:[String:Any]=["associationID":outcome.link.id.uuidString,
                "historyID":outcome.link.historyID.uuidString,"family":outcome.link.family.rawValue,
                "rows":outcome.rows.map {row -> [String:Any] in
                    var fields:[String:Any]=["id":row.id.uuidString,"status":row.status.rawValue,
                        "message":row.message,"requestedArchitecture":row.requestedArchitecture,"reportIncluded":row.reportIncluded]
                    fields["changedCount"]=row.changedCount.map { $0 as Any } ?? NSNull()
                    fields["unchangedCount"]=row.unchangedCount.map { $0 as Any } ?? NSNull()
                    return fields
                }]
             item["absence"]=outcome.absence.map { $0.rawValue as Any } ?? NSNull()
             item["batchID"]=outcome.batchID.map { $0.uuidString as Any } ?? NSNull()
             item["cancelled"]=outcome.cancelled.map { $0 as Any } ?? NSNull()
             item["finishedAt"]=outcome.finishedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
             return item
         }]
    }
}
