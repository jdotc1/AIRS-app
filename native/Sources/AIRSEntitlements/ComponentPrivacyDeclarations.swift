import Foundation
import AIRSCore
public enum ComponentPrivacyDeclarations {
    public static func capture(_ unit: BundleImageProvenance, componentID: UUID) -> DeclarationObservation {
        var source = unit.relativePath
        do {
            let location = try CodeUnitPreflight.inspect(unit)
            source = location.resourcePath + "/PrivacyInfo.xcprivacy"
            do {
                let bytes = try CodeUnitPreflight.data(unit, relativePath: source)
                let value = DeclarationObservation(componentID: componentID, category: .privacy, relativeSource: source, state: .present, bytes: bytes)
                _ = try value.values(); return value
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == 2 {
                return .init(componentID: componentID, category: .privacy, relativeSource: source, state: .notPresent)
            }
        } catch {
            return .init(componentID: componentID, category: .privacy, relativeSource: source, state: .unavailable, issue: "Privacy manifest extraction unavailable: " + error.localizedDescription)
        }
    }
}
