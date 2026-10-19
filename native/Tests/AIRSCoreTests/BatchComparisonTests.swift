import Foundation
import XCTest
@testable import AIRSCore

private actor ComparisonCount {
    var value = 0
    func add() { value += 1 }
    func read() -> Int { value }
}
final class BatchComparisonTests: XCTestCase {
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func raw(_ name: String) throws -> Data { try Data(contentsOf: project.appendingPathComponent("examples/\(name)")) }
    private func item(_ name: String, raw: Data, status: ImageBatchStatus = .completed) throws -> ImageBatchItem {
        let report = try AuditReport.decode(raw)
        return ImageBatchItem(id: UUID(), input: URL(fileURLWithPath: "/owned/\(name)"), status: status,
            message: "Original outcome", retainedReportID: UUID(), image: report.image, summary: report.summary,
            model: report.generator.analysisModelVersion)
    }
    private func plan(_ old: [ImageBatchItem], _ new: [ImageBatchItem]) throws -> BatchComparisonPlan {
        try BatchComparisonPlan(baseline: ImageBatchSnapshot(id: UUID(), items: old, settled: true), current: ImageBatchSnapshot(id: UUID(), items: new, settled: true))
    }
    private func retained(_ data: Data) throws -> RetainedReport {
        RetainedReport(data: data, report: try AuditReport.decode(data), provenance: LibraryProvenance(sourceLabel: "Owned saved report"))
    }
    func testUniqueSuggestionsAndExplicitPinsRejectDuplicatesAndForeignRows() throws {
        let data = try raw("before.audit.json"), old = try item("same", raw: data), new = try item("renamed", raw: data)
        let single = try plan([old], [new]); XCTAssertEqual(single.suggestions.count, 1)
        let duplicate = try item("same", raw: data)
        XCTAssertTrue(try plan([old, duplicate], [new]).suggestions.isEmpty)
        XCTAssertTrue(try plan([old], [new, duplicate]).suggestions.isEmpty)
        XCTAssertThrowsError(try single.validate([BatchImagePair(baselineID: UUID(), currentID: new.id)]))
        XCTAssertThrowsError(try plan([old], [new, duplicate]).validate([
            BatchImagePair(baselineID: old.id, currentID: new.id), BatchImagePair(baselineID: old.id, currentID: duplicate.id)]))
        let different = try item("same", raw: raw("after.audit.json"))
        XCTAssertTrue(try plan([old], [different]).suggestions.isEmpty, "Filename must not imply pairing")
    }
    func testExplicitComparisonPreservesBytesAndFullDenominatorAndExports() async throws {
        let before = try raw("before.audit.json"), after = try raw("after.audit.json"), diff = try raw("before-after.diff.json")
        let old = try item("old", raw: before), new = try item("new", raw: after)
        let failed = try item("failed", raw: before, status: .failed), unfinished = try item("unfinished", raw: after, status: .notStarted)
        let plan = try plan([old, failed], [new, unfinished])
        let oldReport = try retained(before), newReport = try retained(after)
        let result = try await BatchComparisonRunner().run(plan: plan, pairs: [BatchImagePair(baselineID: old.id, currentID: new.id)], load: { id in id == old.retainedReportID ? oldReport : newReport }, compare: { old, new in
            XCTAssertEqual(old, before); XCTAssertEqual(new, after); return diff
        })
        XCTAssertEqual(result.rows.map(\.state), ["compared", "unpaired_current", "unpaired_baseline"])
        XCTAssertEqual(result.rows[0].comparison?.summary.changedCount, 2)
        XCTAssertEqual(result.rows[0].comparisonData, diff)
        let export = try XCTUnwrap(JSONSerialization.jsonObject(with: result.exportData()) as? [String: Any])
        XCTAssertEqual(export["baseline_selected_count"] as? Int, 2)
        XCTAssertEqual(export["current_selected_count"] as? Int, 2)
        XCTAssertEqual((export["rows"] as? [Any])?.count, 3)
        XCTAssertEqual(export["pairing_policy"] as? String, "explicit_one_to_one")
    }
    func testMissingReportAndWrongIdentityRemainUnavailableAndContinue() async throws {
        let before = try raw("before.audit.json"), after = try raw("after.audit.json")
        let old = try item("old", raw: before), new = try item("new", raw: after)
        let report = try retained(after), count = ComparisonCount()
        let result = try await BatchComparisonRunner().run(plan: plan([old], [new]), pairs: [BatchImagePair(baselineID: old.id, currentID: new.id)], load: { _ in report }, compare: { _, _ in await count.add(); return Data() })
        XCTAssertEqual(result.rows.first?.state, "unavailable"); let calls = await count.read(); XCTAssertEqual(calls, 0)
        let missing = try await BatchComparisonRunner().run(plan: plan([old], [new]), pairs: [BatchImagePair(baselineID: old.id, currentID: new.id)], load: { _ in throw CocoaError(.fileNoSuchFile) }, compare: { _, _ in Data() })
        XCTAssertEqual(missing.rows.first?.state, "unavailable")
    }
    func testIncompatibleModelsAndConfigurationWarningDoNotBecomeAgreement() async throws {
        let before = try raw("before.audit.json"), after = try raw("after.audit.json"), diff = try raw("before-after.diff.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        var generator = try XCTUnwrap(object["generator"] as? [String: Any]); generator["analysis_model_version"] = "arm64-bounded-sequential-loops-v31"; object["generator"] = generator
        let changed = try JSONSerialization.data(withJSONObject: object)
        let old = try item("old", raw: before), new = try item("new", raw: changed)
        let oldReport = try retained(before), newReport = try retained(changed)
        let result = try await BatchComparisonRunner().run(plan: plan([old], [new]), pairs: [BatchImagePair(baselineID: old.id, currentID: new.id)], load: { id in id == old.retainedReportID ? oldReport : newReport }, compare: { _, _ in XCTFail("Incompatible models compared"); return diff })
        XCTAssertEqual(result.rows[0].state, "incompatible")
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any]); object.removeValue(forKey: "analysis_config")
        let missingConfig = try JSONSerialization.data(withJSONObject: object), configNew = try item("config", raw: missingConfig), configReport = try retained(missingConfig)
        let warning = try await BatchComparisonRunner().run(plan: plan([old], [configNew]), pairs: [BatchImagePair(baselineID: old.id, currentID: configNew.id)], load: { id in id == old.retainedReportID ? oldReport : configReport }, compare: { _, _ in diff })
        XCTAssertTrue(warning.rows[0].configurationChanged)
    }
    func testCancellationKeepsCompletedPairsAndRejectsSwappedDiffIdentity() async throws {
        let before = try raw("before.audit.json"), after = try raw("after.audit.json"), diff = try raw("before-after.diff.json")
        let olds = try [item("old1", raw: before), item("old2", raw: before)], news = try [item("new1", raw: after), item("new2", raw: after)]
        let plan = try plan(olds, news), oldReport = try retained(before), newReport = try retained(after), count = ComparisonCount()
        let result = try await BatchComparisonRunner().run(plan: plan, pairs: zip(olds,news).map { BatchImagePair(baselineID: $0.id, currentID: $1.id) }, load: { id in olds.contains { $0.retainedReportID == id } ? oldReport : newReport }, compare: { _, _ in
            await count.add(); if await count.read() == 2 { throw CancellationError() }; return diff
        })
        XCTAssertEqual(result.rows.map(\.state), ["compared", "not_compared"]); XCTAssertTrue(result.cancelled)
        let wrong = try await BatchComparisonRunner().run(plan: plan, pairs: [BatchImagePair(baselineID: olds[0].id, currentID: news[0].id)], load: { id in olds.contains { $0.retainedReportID == id } ? newReport : oldReport }, compare: { _, _ in diff })
        XCTAssertEqual(wrong.rows[0].state, "unavailable")
    }
    func testUnavailablePairDoesNotSuppressLaterComparisonAndWrongOutputRefuses() async throws {
        let before = try raw("before.audit.json"), after = try raw("after.audit.json"), diff = try raw("before-after.diff.json")
        let olds = try [item("missing", raw: before), item("valid", raw: before)]
        let news = try [item("first", raw: after), item("second", raw: after)]
        let oldReport = try retained(before), newReport = try retained(after)
        let result = try await BatchComparisonRunner().run(plan: plan(olds, news), pairs: zip(olds, news).map { BatchImagePair(baselineID: $0.id, currentID: $1.id) }, load: { id in
            if id == olds[0].retainedReportID { throw CocoaError(.fileNoSuchFile) }
            return id == olds[1].retainedReportID ? oldReport : newReport
        }, compare: { _, _ in diff })
        XCTAssertEqual(result.rows.map(\.state), ["unavailable", "compared"])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: diff) as? [String: Any])
        var context = try XCTUnwrap(object["comparison"] as? [String: Any])
        let oldIdentity = context["baseline_image"]; context["baseline_image"] = context["current_image"]; context["current_image"] = oldIdentity
        object["comparison"] = context
        let swapped = try JSONSerialization.data(withJSONObject: object)
        let refused = try await BatchComparisonRunner().run(plan: plan([olds[1]], [news[1]]), pairs: [BatchImagePair(baselineID: olds[1].id, currentID: news[1].id)], load: { id in id == olds[1].retainedReportID ? oldReport : newReport }, compare: { _, _ in swapped })
        XCTAssertEqual(refused.rows[0].state, "unavailable"); XCTAssertNil(refused.rows[0].comparisonData)
    }

}
