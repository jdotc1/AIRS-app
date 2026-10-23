import Foundation
import AIRSEntitlements

struct PortableProjectPreview: Identifiable, Sendable {
    enum Purpose: Sendable { case export, reconstruct }
    let id = UUID()
    let sessionID: UUID
    let purpose: Purpose
    let project: InspectionProject
    let admission: PortableProjectAdmission?
    let settledAdmission:PortableSettledBatchAdmission?
    let sourceURL:URL?
    init(sessionID:UUID,purpose:Purpose,project:InspectionProject,admission:PortableProjectAdmission?,
         settledAdmission:PortableSettledBatchAdmission?=nil,sourceURL:URL?=nil) {
        self.sessionID=sessionID;self.purpose=purpose;self.project=project;self.admission=admission
        self.settledAdmission=settledAdmission;self.sourceURL=sourceURL ?? admission?.packageURL
    }
}
