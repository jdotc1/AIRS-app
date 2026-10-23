import Foundation
import AIRSCore

/// Prepared recipient re-export. Existing admitted project bytes and the detached
/// history are carried together; neither source store nor live queues are rebuilt.
public struct PortableSettledBatchReexport: Sendable {
    public let project: PortableProjectAdmission
    public let history: PortableSettledBatchEvidence
    private let recipientStore: URL
    private let projectFolder: URL
    private let projectFile: URL
    private let projectStamp: ResumeFileIdentity
    private let historyFile: URL
    private let historyStamp: ResumeFileIdentity

    /// The caller supplies an explicit schema-1 project admission. Require that
    /// exact snapshot to still be the recipient's stored project; a matching UUID
    /// alone is insufficient. The existing sidecar binds link IDs and row IDs,
    /// not independently authenticated original library history IDs.
    public static func prepare(project: PortableProjectAdmission, recipientStore: URL) throws -> Self {
        try Task.checkCancellation()
        try PortableProjectReader.validateCurrent(project)
        try PortableProjectFiles.physicalDirectory(recipientStore)
        let projects = recipientStore.appendingPathComponent("Projects")
        let folder = projects.appendingPathComponent(project.project.id.uuidString)
        try PortableProjectFiles.physicalDirectory(projects)
        try PortableProjectFiles.physicalDirectory(folder)
        let projectFile = folder.appendingPathComponent("manifest.json")
        let (metadata, projectStamp) = try BoundReviewFiles.snapshot(projectFile, limit: 2_097_152)
        guard metadata == project.projectBytes else { throw InspectionArchiveError.invalid }
        let historyFile = recipientStore.appendingPathComponent("settled-batches.json")
        let (bytes, historyStamp) = try BoundReviewFiles.snapshot(historyFile, limit: PortableSettledBatchEvidence.maximumBytes)
        let history = try PortableSettledBatchEvidence.decode(bytes, project: project.project)
        let prepared = Self(project: project, history: history, recipientStore: recipientStore,
            projectFolder: folder, projectFile: projectFile, projectStamp: projectStamp,
            historyFile: historyFile, historyStamp: historyStamp)
        try prepared.validateCurrent()
        return prepared
    }

    private func validateCurrent() throws {
        try PortableProjectFiles.physicalDirectory(recipientStore)
        try PortableProjectFiles.physicalDirectory(projectFolder.deletingLastPathComponent())
        try PortableProjectFiles.physicalDirectory(projectFolder)
        guard try ResumeFileIdentity.capture(projectFile) == projectStamp,
              try ResumeFileIdentity.capture(historyFile) == historyStamp else {
            throw BoundReviewError.invalid("Recipient project or historical outcomes changed after preview. Prepare the re-export again.")
        }
        try PortableProjectReader.validateCurrent(project)
    }

    public func write(to target: URL, beforePublish: @Sendable () throws -> Void = {}) throws {
        let destination = target.standardizedFileURL
        guard destination != recipientStore.standardizedFileURL,
              !destination.path.hasPrefix(recipientStore.standardizedFileURL.path + "/"),
              destination != project.packageURL.standardizedFileURL,
              !destination.path.hasPrefix(project.packageURL.standardizedFileURL.path + "/") else {
            throw InspectionArchiveError.invalid
        }
        try Task.checkCancellation()
        try validateCurrent()
        let stage = try PortableProjectFiles.freshStage(for: target)
        defer { try? FileManager.default.removeItem(at: stage) }
        let package = stage.appendingPathComponent("package")
        // The existing writer admits the newly created companion once. Our outer
        // stage lets source-currentness fail before any final destination appears,
        // without re-admitting or rehashing the unchanged intermediate package.
        try PortableSettledBatchProject.write(project, history: history, to: package)
        try Task.checkCancellation()
        try beforePublish()
        try Task.checkCancellation()
        try validateCurrent()
        try FileManager.default.moveItem(at: package, to: target)
    }
}
