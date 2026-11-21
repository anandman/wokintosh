import XCTest
@testable import WokintoshCore

final class PublishedWidgetsTests:XCTestCase {
    let now=Date(timeIntervalSince1970:1800000000)
    func row(_ id:String,host:String="source",state:AgentState = .working)->SessionRow {
        SessionRow(hostID:host,hostName:host,session:AgentSession(id:id,provider:"codex",title:"Title "+id,project:"Project",state:state,updatedAt:now))
    }
    func payload(_ rows:[SessionRow],at time:Date?=nil)->PublishedAgents {
        PublishedAgents.make(rows:rows,sourceObservations:["source":time ?? now,"other":now],interval:.minutes15,showFinished:true,at:now)
    }
    func testProjectionMirrorsAttentionAndCollapseWhileDisclosingOverflow() {
        var done=row("done",state:.finished);done.completionPending=true;done.completionObservedAt=now.addingTimeInterval(-1000)
        let rows=(0..<140).map{row("busy-\($0)")}+[row("needs",state:.needsAttention),done]
        let p=payload(rows)
        XCTAssertEqual(p.rows.first?.session.id,"needs")
        XCTAssertEqual(p.rows.count,128)
        XCTAssertEqual(p.totalCount,141)
        XCTAssertEqual(p.hiddenCount,13)
        XCTAssertEqual(p.earlierDoneCount,1)
        XCTAssertEqual(p.attentionCount,1)
        XCTAssertEqual(p.doneCount,1)
        XCTAssertFalse(p.rows.contains{$0.session.id=="done"})
    }
    func testNewEnvelopeCannotRefreshAnOldSourceAndOfflineWins() {
        let p=payload([row("old")],at:now.addingTimeInterval(-1900))
        XCTAssertEqual(p.asOf,now.addingTimeInterval(-1900))
        XCTAssertEqual(p.rows[0].freshness(at:now),.stale)
        var offline=row("offline");offline.connected=false
        XCTAssertEqual(payload([offline]).rows[0].freshness(at:now),.offline)
        XCTAssertEqual(payload([row("future")],at:now.addingTimeInterval(500)).rows[0].freshness(at:now),.stale)
    }
    func testSameSessionIDsOnDifferentHostsRouteOnlyToTheirOwnRows() throws {
        let p=payload([row("same"),row("same",host:"other")])
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:p)
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:[widget])
        XCTAssertNotEqual(p.rows[0].id,p.rows[1].id)
        let route=PhoneRoute(publisherID:feed.publisherID,widgetID:widget.id,rowID:p.rows[1].id)
        XCTAssertEqual(PhoneRoute(url:route.url)?.resolve(in:feed)?.hostID,p.rows[1].hostID)
        let other=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Other",publishedAt:now,widgets:[widget])
        XCTAssertNil(route.resolve(in:other))
        XCTAssertNil(PhoneRoute(url:URL(string:"wokintosh://session?url=claude://code/anything")!))
    }
    func testUnknownWidgetVersionsAndMalformedNeighborsAreIndependentlyIgnored() throws {
        let widget=PublishedWidget(id:UUID(),name:"Agents",agents:payload([row("valid")]))
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:[widget])
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:feed.encoded()) as? [String:Any])
        let good=try XCTUnwrap((json["widgets"] as? [[String:Any]])?.first)
        var future=good;future["id"]=UUID().uuidString;future["payloadVersion"]=99
        json["widgets"]=[future,["kind":"future","payload":[]],good]
        let recovered=try PublishedWidgetFeed.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(recovered.widgets.map(\.id),[widget.id])
        XCTAssertEqual(recovered.widgets.first?.agents?.rows.first?.session.id,"valid")
        json["version"]=999
        XCTAssertThrowsError(try PublishedWidgetFeed.decode(JSONSerialization.data(withJSONObject:json)))
    }
    func testLargeFeedSharesItsByteBudgetAcrossOrderedPrefixes() throws {
        let rows=(0..<128).map{index -> SessionRow in
            var r=row("id-\(index)");r.session.title=String(repeating:"界",count:180);return r
        }
        let source=payload(rows)
        let widgets=(0..<64).map{_ in PublishedWidget(id:UUID(),name:"Agents",agents:source)}
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:widgets)
        let recovered=try PublishedWidgetFeed.decode(feed.encoded())
        let counts=recovered.widgets.map{$0.agents!.rows.count}
        XCTAssertLessThanOrEqual(counts.max()!-counts.min()!,1)
        for widget in recovered.widgets {
            let agents=try XCTUnwrap(widget.agents)
            XCTAssertEqual(agents.rows,Array(source.rows.prefix(agents.rows.count)))
            XCTAssertEqual(agents.totalCount,128)
        }
    }
    func testEncodingBoundsBytesWithoutFalsifyingCounts() throws {
        let rows=(0..<128).map{index -> SessionRow in
            var r=row("id-\(index)");r.session.title=String(repeating:"界",count:180);return r
        }
        let widgets=(0..<24).map{PublishedWidget(id:UUID(),name:"Agents \($0)",agents:payload(rows))}
        let feed=PublishedWidgetFeed(publisherID:UUID(),publisherName:"Display",publishedAt:now,widgets:widgets)
        let data=try feed.encoded()
        XCTAssertLessThanOrEqual(data.count,PublishedWidgetFeed.maximumBytes)
        let recovered=try PublishedWidgetFeed.decode(data)
        XCTAssertTrue(recovered.widgets.contains{($0.agents?.rows.count ?? 128)<128})
        for w in recovered.widgets {
            let p=try XCTUnwrap(w.agents)
            XCTAssertEqual(p.totalCount,128)
            XCTAssertEqual(p.hiddenCount+p.rows.count,128)
        }
        XCTAssertThrowsError(try PublishedWidgetFeed.decode(Data(repeating:32,count:PublishedWidgetFeed.maximumBytes+1)))
    }
}
