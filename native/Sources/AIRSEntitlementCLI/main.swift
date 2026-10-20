import Foundation
import Darwin
import EntitlementDiffCLIKit
import EntitlementDiffSecurity
import AIRSEntitlements

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    do { try FileHandle.standardOutput.write(contentsOf: Data((ComparisonCommand.usage.replacingOccurrences(of: "entitlementdiff-cli", with: "airs-entitlements") + "\n\n" + EntitlementBatchCommand.usage + "\n\n" + ReviewPolicyCommand.usage + "\n").utf8)) }
    catch { exit(2) }
    exit(0)
}
do {
    if arguments.first == "review" {
        if Array(arguments.dropFirst()) == ["--help"] {
            try FileHandle.standardOutput.write(contentsOf:Data((ReviewPolicyCommand.usage+"\n").utf8));exit(0)
        }
        let result=try await ReviewPolicyCommand(arguments:Array(arguments.dropFirst())).run()
        try FileHandle.standardOutput.write(contentsOf:result.standardOutput)
        exit(result.exitStatus)
    }
    if arguments.first == "batch" {
        if Array(arguments.dropFirst()) == ["--help"] {
            try FileHandle.standardOutput.write(contentsOf: Data((EntitlementBatchCommand.usage + "\n").utf8))
            exit(0)
        }
        let command = try EntitlementBatchCommand(arguments: Array(arguments.dropFirst()))
        let result = try await command.run(reader: SecurityEntitlementReader())
        try FileHandle.standardOutput.write(contentsOf: result.standardOutput)
        if result.exitStatus == 2 {
            try FileHandle.standardError.write(contentsOf: Data("airs-entitlements: batch incomplete; inspect summary.json for per-pair outcomes.\n".utf8))
        }
        exit(result.exitStatus)
    }
    let command = try ComparisonCommand(arguments: arguments)
    let result = try await command.run(reader: SecurityEntitlementReader())
    try FileHandle.standardOutput.write(contentsOf: result.standardOutput)
    exit(result.exitStatus)
} catch {
    // Diagnostics are separate from JSON reports and batch summaries.
    try? FileHandle.standardError.write(contentsOf: Data(("airs-entitlements: " + error.localizedDescription + "\n").utf8))
    exit(2)
}
