import Foundation
import AIRSCore
import AIRSEntitlements

/// One immutable consent snapshot. No live queue or history-store replacement.
struct SettledProjectExportPreview:Identifiable,Sendable {
    enum Purpose:Sendable {case export,reexport}
    let id=UUID()
    let sessionID:UUID
    let purpose:Purpose
    let sourceStore:URL
    let package:PortableProjectAdmission
    let history:PortableSettledBatchEvidence
    let recipient:PortableSettledBatchReexport?
    private let projectFile:URL
    private let projectStamp:ResumeFileIdentity

    static func prepare(packageURL:URL,store:URL,selected:InspectionProject,sessionID:UUID,
                        purpose:Purpose,historyReader:@Sendable (InspectionProject) async throws -> PortableSettledBatchEvidence) async throws -> Self {
        let packageFile=packageURL.appendingPathComponent("project.json")
        let packageStamp=try ResumeFileIdentity.capture(packageFile)
        let admitted=try PortableProjectReader.prepare(at:packageURL)
        guard admitted.project.id == selected.id,admitted.project.revision == selected.revision,
              try admitted.project.data() == selected.data() else {throw BoundReviewError.invalid("Choose the exact package for the selected project and revision.")}
        let projectFile=store.appendingPathComponent("Projects").appendingPathComponent(selected.id.uuidString).appendingPathComponent("manifest.json")
        let stamp=try ResumeFileIdentity.capture(projectFile)
        let stored=try BoundReviewFiles.read(projectFile,limit:2_097_152)
        let packaged=try BoundReviewFiles.read(packageFile,limit:2_097_152)
        guard stored == packaged,try ResumeFileIdentity.capture(packageFile) == packageStamp,
              try ResumeFileIdentity.capture(projectFile) == stamp else {throw BoundReviewError.invalid("Package metadata must match the selected store's exact original project bytes.")}
        let recipient:PortableSettledBatchReexport?
        let history:PortableSettledBatchEvidence
        if purpose == .reexport {
            let prepared=try PortableSettledBatchReexport.prepare(project:admitted,recipientStore:store)
            recipient=prepared;history=prepared.history
        } else {recipient=nil;history=try await historyReader(admitted.project)}
        try Task.checkCancellation()
        let value=Self(sessionID:sessionID,purpose:purpose,sourceStore:store,package:admitted,history:history,
                       recipient:recipient,projectFile:projectFile,projectStamp:stamp)
        try value.validateStoreCurrent();return value
    }
    func matches(session:ProjectReviewSession?,store:URL)->Bool {
        session?.id == sessionID && session?.project?.id == package.project.id
            && session?.project?.revision == package.project.revision
            && store.standardizedFileURL == sourceStore.standardizedFileURL
    }
    private func validateStoreCurrent() throws {
        guard try ResumeFileIdentity.capture(projectFile) == projectStamp else {
            throw BoundReviewError.invalid("Project metadata changed after preview. Prepare the export again.")
        }
    }
    func write(to target:URL) throws {
        try Task.checkCancellation();try validateStoreCurrent()
        if let recipient {try recipient.write(to:target);return}
        // The qualified companion writer validates its admitted package. An outer
        // stage lets the store witness fail before this adapter publishes output.
        let stage=target.deletingLastPathComponent().appendingPathComponent(".airs-native-companion-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false)
        defer {try? FileManager.default.removeItem(at:stage)}
        let companion=stage.appendingPathComponent("companion")
        try PortableSettledBatchProject.write(package,history:history,to:companion)
        try Task.checkCancellation();try validateStoreCurrent()
        try FileManager.default.moveItem(at:companion,to:target)
    }
}
