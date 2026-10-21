import Foundation
import AIRSEntitlements

struct PortableProjectPreview: Identifiable, Sendable {
    enum Purpose: Sendable { case export, reconstruct }
    let id = UUID()
    let sessionID: UUID
    let purpose: Purpose
    let project: InspectionProject
    let admission: PortableProjectAdmission?
}
