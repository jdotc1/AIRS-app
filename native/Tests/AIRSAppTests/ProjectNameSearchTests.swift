import XCTest
@testable import AIRSEntitlements
@testable import AIRSApp

final class ProjectNameSearchTests:XCTestCase {
    func testDisplayNameMatchingFoldsCaseAndDiacriticsAndUsesLiteralSubstrings() {
        XCTAssertTrue(ProjectNameSearch.includes(name:"Café Release",query:"CAFE"))
        XCTAssertTrue(ProjectNameSearch.includes(name:"Café Release",query:"  fé rel\n"))
        XCTAssertFalse(ProjectNameSearch.includes(name:"Café Release",query:".*"))
        XCTAssertFalse(ProjectNameSearch.includes(name:"Café Release",query:"missing"))
    }

    func testBlankQueryPreservesOrderAndUnreadableRowsRemainVisible() {
        let first=InspectionProject(name:"First"),second=InspectionProject(name:"Second")
        let unreadable=InspectionProjectEntry(id:UUID(),project:nil,issue:"Unreadable manifest")
        let entries=[InspectionProjectEntry(id:first.id,project:first,issue:nil),unreadable,
                     InspectionProjectEntry(id:second.id,project:second,issue:nil)]
        XCTAssertEqual(ProjectNameSearch.visibleEntries(entries,query:" \t ").map(\.id),entries.map(\.id))
        let visible=ProjectNameSearch.visibleEntries(entries,query:"second")
        XCTAssertEqual(visible.map(\.id),[unreadable.id,second.id])
        XCTAssertEqual(visible.first?.issue,"Unreadable manifest")
    }

    func testFilteringSessionEntriesDoesNotChangeSelectedDetailsAndClearingRestoresRows() {
        let selected=InspectionProject(name:"Selected"),other=InspectionProject(name:"Other")
        let entries=[InspectionProjectEntry(id:selected.id,project:selected,issue:nil),
                     InspectionProjectEntry(id:other.id,project:other,issue:nil)]
        let session=ProjectReviewSession(entries:entries,project:selected)
        XCTAssertEqual(ProjectNameSearch.visibleEntries(session.entries,query:"other").map(\.id),[other.id])
        XCTAssertEqual(session.project?.id,selected.id)
        XCTAssertEqual(session.project?.name,"Selected")
        XCTAssertEqual(ProjectNameSearch.visibleEntries(session.entries,query:"").map(\.id),entries.map(\.id))
        XCTAssertTrue(ProjectNameSearch.visibleEntries(session.entries,query:"no match").isEmpty)
        XCTAssertEqual(session.project?.id,selected.id)
    }
}
