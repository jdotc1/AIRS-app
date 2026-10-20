import Foundation
import AIRSCore
public enum ComponentLoaderDeclarations {
    public static func capture(_ unit: BundleImageProvenance, componentID: UUID, architecture: String, budget: inout Int) -> DeclarationObservation {
        var reader = ComponentMetadataReader(maximumHeaderBytes: budget)
        defer { budget -= reader.bytesRead }
        do {
            let rows = try reader.readLoadCommands(.forCodeUnit(unit)).filter { $0.architecture == architecture }
            guard reader.observedArchitectures.contains(architecture) else { throw InspectionArchiveError.invalid }
            let bytes = try JSONEncoder().encode(rows)
            let values = try JSONSerialization.jsonObject(with: bytes)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["commands": values], format: .binary, options: 0)
            guard plist.count <= 65_536 else { throw InspectionArchiveError.limit }
            return .init(componentID: componentID, category: .loadCommands, architecture: architecture, relativeSource: unit.relativePath, state: .present, bytes: plist)
        } catch {
            return .init(componentID: componentID, category: .loadCommands, architecture: architecture, relativeSource: unit.relativePath, state: .unavailable, issue: "Loader declarations unavailable: " + error.localizedDescription)
        }
    }
}
