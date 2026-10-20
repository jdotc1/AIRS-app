import Foundation
import AIRSCore
public enum ComponentInfoDeclarations {
    public static func capture(_ unit: BundleImageProvenance, componentID: UUID) -> DeclarationObservation {
        do {
            let location = try CodeUnitPreflight.inspect(unit)
            let observation = DeclarationObservation(componentID: componentID, category: .info, relativeSource: location.infoPath, state: .present, bytes: location.infoBytes)
            _ = try observation.values()
            return observation
        } catch {
            return .init(componentID: componentID, category: .info, relativeSource: unit.relativePath, state: .unavailable, issue: "Info declaration extraction unavailable: " + error.localizedDescription)
        }
    }
}
