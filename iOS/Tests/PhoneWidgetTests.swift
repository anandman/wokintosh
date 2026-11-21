import XCTest
import WokintoshCore

final class PhoneWidgetTests:XCTestCase {
    func testSelectionIncludesPublisherAndDoesNotFallBackToAnotherWidget() {
        let feed=PhoneFixtures.feed(),snapshot=PhoneSnapshot(feed:feed,state:.current,lastFetchedAt:Date(),paired:true)
        let selected=AgentWidgetEntry.scopedID(publisher:feed.publisherID,widget:feed.widgets[0].id)
        XCTAssertEqual(AgentWidgetEntry.make(snapshot:snapshot,selection:selected,at:Date()).widget?.id,feed.widgets[0].id)
        let wrong=AgentWidgetEntry.scopedID(publisher:UUID(),widget:feed.widgets[0].id)
        XCTAssertNil(AgentWidgetEntry.make(snapshot:snapshot,selection:wrong,at:Date()).widget)
        XCTAssertEqual(AgentWidgetEntry.make(snapshot:snapshot,selection:nil,at:Date()).widget?.id,feed.widgets[0].id)
    }
}
