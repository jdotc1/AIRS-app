import Foundation

public enum InventoryCompletion: String, Codable, Sendable {
    case completeWithinScope, partial, cancelled, failed
}
public struct InventoryScope: Codable, Sendable {
    public let searchedLocations: [String]
    public let completion: InventoryCompletion
    public let exclusions: [String]
    public let issues: [String]
    public init(searchedLocations: [String], completion: InventoryCompletion, exclusions: [String], issues: [String]) {
        self.searchedLocations = searchedLocations; self.completion = completion
        self.exclusions = exclusions; self.issues = issues
    }
}
public struct ComponentRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let relativePath: String
    public let kind: String
    public let declaredBundleID: String?
    public let declaredVersion: String?
    public let architectures: [String]
    public let minimumOSByArchitecture: [String: String]
    public let readIssues: [String]
    public init(id: UUID = UUID(), parentID: UUID? = nil, relativePath: String, kind: String,
                declaredBundleID: String? = nil, declaredVersion: String? = nil, architectures: [String] = [],
                minimumOSByArchitecture: [String: String] = [:], readIssues: [String] = []) {
        self.id = id; self.parentID = parentID; self.relativePath = relativePath; self.kind = kind
        self.declaredBundleID = declaredBundleID; self.declaredVersion = declaredVersion
        self.architectures = architectures; self.minimumOSByArchitecture = minimumOSByArchitecture; self.readIssues = readIssues
    }
    func parented(_ parent: UUID?) -> Self {
        .init(id: id, parentID: parent, relativePath: relativePath, kind: kind,
              declaredBundleID: declaredBundleID, declaredVersion: declaredVersion,
              architectures: architectures, minimumOSByArchitecture: minimumOSByArchitecture, readIssues: readIssues)
    }
}
public struct ComponentInventory: Codable, Sendable, Identifiable {
    public let id: UUID
    public let capturedAt: Date
    public let scope: InventoryScope
    public let components: [ComponentRecord]
    public init(id: UUID = UUID(), capturedAt: Date = Date(), scope: InventoryScope, components: [ComponentRecord]) {
        self.id = id; self.capturedAt = capturedAt; self.scope = scope; self.components = components
    }
    public var observedIntelOnly: [ComponentRecord] {
        components.filter { !$0.architectures.isEmpty && $0.architectures.allSatisfy { ["i386", "x86_64", "x86_64h"].contains($0) } }
    }
    public func validate() throws {
        guard components.count <= 128, Set(components.map(\.id)).count == components.count,
              Set(components.map { Data($0.relativePath.utf8) }).count == components.count,
              capturedAt.timeIntervalSince1970.isFinite,
              scope.searchedLocations.count <= 16, scope.exclusions.count <= 256, scope.issues.count <= 256 else {
            throw ReportError.invalidContents("Invalid or oversized component inventory.")
        }
        let ids = Set(components.map(\.id))
        for record in components {
            let parts = record.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }),
                  record.relativePath.utf8.count <= 4096, record.kind.utf8.count <= 64,
                  record.parentID.map({ ids.contains($0) && $0 != record.id }) ?? true,
                  record.architectures.count <= 64, Set(record.architectures).count == record.architectures.count,
                  record.minimumOSByArchitecture.count <= 64, record.readIssues.count <= 64,
                  record.minimumOSByArchitecture.keys.allSatisfy(record.architectures.contains) else {
                throw ReportError.invalidContents("Invalid component identity, path or declaration limits.")
            }
            let strings = [record.kind, record.declaredBundleID, record.declaredVersion].compactMap { $0 } + record.architectures + Array(record.minimumOSByArchitecture.values)
            guard strings.allSatisfy({ $0.utf8.count <= 256 }), record.readIssues.allSatisfy({ $0.utf8.count <= 4096 }) else { throw ReportError.invalidContents("Component text exceeds limits.") }
            var visited = Set<UUID>(), next = record.parentID
            while let parent = next {
                guard visited.insert(parent).inserted else { throw ReportError.invalidContents("Cyclic component parents.") }
                next = components.first(where: { $0.id == parent })?.parentID
            }
        }
        guard (scope.searchedLocations + scope.exclusions + scope.issues).allSatisfy({ $0.utf8.count <= 4096 }) else { throw ReportError.invalidContents("Inventory scope exceeds limits.") }
    }
    enum Key: String, CodingKey { case id, capturedAt, scope, components }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .id); capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        scope = try c.decode(InventoryScope.self, forKey: .scope)
        var records = try c.nestedUnkeyedContainer(forKey: .components)
        guard (records.count ?? 129) <= 128 else { throw ReportError.invalidContents("Component record limit exceeded.") }
        var values: [ComponentRecord] = []
        while !records.isAtEnd { values.append(try records.decode(ComponentRecord.self)) }
        components = values
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id); try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(scope, forKey: .scope); try c.encode(components, forKey: .components)
    }
}

public struct ComponentInventoryBuilder: Sendable {
    private let limits: BundleDiscovery.Limits
    public init(limits: BundleDiscovery.Limits = .init()) { self.limits = limits }
    public func build(_ selectedApp: URL) throws -> ComponentInventory { try capture(selectedApp).inventory }
    public func capture(_ selectedApp: URL) throws -> LiveComponentInventory {
        let discovery = try BundleDiscovery(limits: limits).discover(selectedApp)
        var budget = limits.headerBytes - discovery.headerBytes
        var records: [ComponentRecord] = [], issues: [String] = [], exclusions: [String] = []
        var partial = discovery.partial
        for entry in discovery.entries {
            if ["skipped_link", "skipped_special", "duplicate_file"].contains(entry.state) {
                if exclusions.count < 255 { exclusions.append(entry.relativePath + ": " + entry.message) }
                else { partial = true }
                continue
            }
            guard entry.selectable || !["non_image"].contains(entry.state) else { continue }
            if !entry.selectable {
                partial = true
                if issues.count < 255 { issues.append(entry.relativePath + ": " + entry.message) }
                // Preserve concrete image read failures; synthetic traversal issue paths
                // are scope issues, not invented image records.
                guard !entry.relativePath.contains("["), ["malformed_header", "unsupported_type", "unreadable"].contains(entry.state) else { continue }
            }
            guard records.count < 128 else { partial = true; if issues.count < 255 { issues.append("Component record limit reached.") }; break }
            do {
                if Task.isCancelled { throw CancellationError() }
                var reader = ComponentMetadataReader(maximumHeaderBytes: budget)
                defer { budget -= reader.bytesRead }
                let record = try reader.readConsuming(entry)
                records.append(record)
                if !record.readIssues.isEmpty { partial = true }
            } catch {
                partial = true
                records.append(.init(relativePath: entry.relativePath, kind: ComponentMetadataReader.kind(for: entry.relativePath),
                    readIssues: [error is CancellationError ? "Metadata read cancelled; unavailable." : "Metadata unavailable: " + error.localizedDescription]))
            }
        }
        // Use exact UTF-8 container ancestry. No name/identifier matching.
        let main = records.first { $0.kind == "app" && ComponentMetadataReader.container(for: $0.relativePath).isEmpty }
        records = records.map { record in
            let container = ComponentMetadataReader.container(for: record.relativePath)
            let parent = records.filter { candidate in
                guard candidate.id != record.id else { return false }
                let other = ComponentMetadataReader.container(for: candidate.relativePath)
                return !other.isEmpty && candidate.kind != "image" &&
                    (other.utf8.count < container.utf8.count || (other.utf8.elementsEqual(container.utf8) && record.kind == "image")) &&
                    Data((container + "/").utf8).starts(with: Data((other + "/").utf8))
            }.max { ComponentMetadataReader.container(for: $0.relativePath).utf8.count < ComponentMetadataReader.container(for: $1.relativePath).utf8.count }
            return record.parented(parent?.id ?? (record.id == main?.id ? nil : main?.id))
        }
        if partial && issues.isEmpty { issues.append("Some component declarations are unavailable; inspect per-record issues.") }
        if exclusions.count == 255 { exclusions.append("Additional exclusions may be omitted by the presentation budget.") }
        let inventory = ComponentInventory(id: discovery.id, scope: .init(searchedLocations: discovery.searchedLocations,
            completion: Task.isCancelled || discovery.cancelled ? .cancelled : (partial ? .partial : .completeWithinScope), exclusions: exclusions, issues: issues), components: records)
        try inventory.validate()
        let known = Set(records.map(\.id))
        let units = Dictionary(uniqueKeysWithValues: discovery.entries.compactMap { entry -> (UUID, BundleImageProvenance)? in
            guard known.contains(entry.id), let provenance = entry.provenance else { return nil }
            return (entry.id, provenance)
        })
        return .init(inventory: inventory, units: units)
    }
}

/// Session-only explicit selection capability. Never Codable or restored from imports.
public struct LiveComponentInventory: Sendable {
    public let inventory: ComponentInventory
    public let units: [UUID: BundleImageProvenance]
    public init(inventory: ComponentInventory, units: [UUID: BundleImageProvenance]) { self.inventory = inventory; self.units = units }
}
