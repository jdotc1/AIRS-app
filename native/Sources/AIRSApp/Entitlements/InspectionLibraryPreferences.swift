import Foundation

struct InspectionLibraryPreferences: Codable, Sendable {
    var version: Int = 1
    var pinnedBaselineID: UUID?

    static func read(at url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
