import XCTest
@testable import WokintoshCore

final class SetupTransferTests: XCTestCase {
    private let frame=WidgetFrame(x:0,y:0,width:0.4,height:0.3)
    private func personal() -> DashboardDocument {
        var widget=Widget(kind:.calendar,frame:frame)
        widget.hostID="source-local"
        widget.calendarOptions=CalendarSelectionOptions(calendarIDs:["private-calendar"],excludedTitlePatterns:["secret"])
        widget.weatherOptions=WeatherWidgetOptions(place:"Home",latitude:10,longitude:20,fahrenheit:true)
        widget.systemOptions.driveIDs=["/Volumes/Private"]
        widget.action=WidgetAction(kind:.openURL,applicationBundleID:"private.app",applicationName:"Private",url:"https://example.com/private")
        var document=DashboardDocument(widgets:[widget]);document.textScale=1.25;document.snapToGrid=false
        document.remoteHosts=[RemoteHost(name:"Minion",destination:"minion")]
        document.displayID=99;document.presentationEnabled=true;document.previewMode=true
        document.weatherPlace="Legacy private";document.latitude=50;document.longitude=60
        return document
    }
    func testPersonalRoundTripContainsPortableChoicesAndNoRuntimeOrDisplayState() throws {
        let source=personal()
        let setup=DashboardSetup.export(document:source,kind:.setup,machines:[SetupMachineReference(id:"source-local",name:"Source",isLocal:true)])
        let data=try setup.encoded()
        let restored=try DashboardSetup.decode(data)
        XCTAssertEqual(restored.widgets,source.widgets)
        XCTAssertEqual(restored.remoteHosts,source.remoteHosts)
        XCTAssertEqual(restored.textScale,1.25)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        for key in ["completions","blockedSessions","reportedBlockedSessions","displayID","previewMode","weatherPlace","latitude","presentationEnabled"] { XCTAssertNil(json[key],key) }
        XCTAssertEqual(restored.defaultMachineMapping(localHostID:"destination-local"),["source-local":"destination-local"])
    }
    func testTemplatesRemovePersonalOptionsEvenOnUnrelatedWidgetKinds() throws {
        let original=personal()
        let exported=DashboardSetup.export(document:original,kind:.template)
        let template=try DashboardSetup.decode(exported.encoded())
        XCTAssertTrue(template.remoteHosts.isEmpty);XCTAssertTrue(template.machines.isEmpty)
        let widget=try XCTUnwrap(template.widgets.first)
        XCTAssertNotEqual(widget.id,original.widgets.first?.id)
        XCTAssertNil(widget.hostID);XCTAssertNil(widget.systemOptions.driveIDs)
        XCTAssertEqual(widget.calendarOptions.calendarIDs,[])
        XCTAssertTrue(widget.calendarOptions.excludedTitlePatterns.isEmpty)
        XCTAssertEqual(widget.weatherOptions.place,"");XCTAssertNil(widget.weatherOptions.latitude)
        XCTAssertTrue(widget.weatherOptions.fahrenheit)
        XCTAssertEqual(widget.action,WidgetAction())
        let text=String(decoding:try template.encoded(),as:UTF8.self)
        for secret in ["Private","private-calendar","secret","Home","minion","Legacy private","source-local"] { XCTAssertFalse(text.contains(secret),secret) }
    }
    func testForgedTemplateIsSanitizedOnImport() throws {
        let data=try DashboardSetup.export(document:personal(),kind:.setup).encoded()
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);json["kind"]="template"
        let imported=try DashboardSetup.decode(JSONSerialization.data(withJSONObject:json))
        XCTAssertTrue(imported.remoteHosts.isEmpty);XCTAssertNil(imported.widgets.first?.hostID)
        XCTAssertEqual(imported.widgets.first?.action.kind,WidgetActionKind.none)
        XCTAssertEqual(imported.widgets.first?.calendarOptions.calendarIDs,[])
    }
    func testImportReplacesWidgetsMergesMachinesAndPreservesLocalState() throws {
        let source=personal()
        let setup=DashboardSetup.export(document:source,kind:.setup)
        var target=DashboardDocument(widgets:[Widget(kind:.clock,frame:frame)])
        var existing=source.remoteHosts[0];existing.id=UUID();existing.name="Existing name";existing.enabled=false
        target.remoteHosts=[existing,RemoteHost(name:"Other",destination:"other")]
        target.displayID=42;target.presentationEnabled=false;target.showDockIcon=false;target.previewMode=false
        target.completions.ingest([],connectedHostIDs:["target"],at:Date(timeIntervalSince1970:1))
        target.completions.ingest([SessionRow(hostID:"target",hostName:"Target",session:AgentSession(id:"done",provider:"codex",title:"Target task",project:"",state:.finished,updatedAt:Date(timeIntervalSince1970:2)))],at:Date(timeIntervalSince1970:3))
        let applied=try setup.applying(to:target,machineMapping:["source-local":"target-local"])
        XCTAssertEqual(applied.widgets.count,1);XCTAssertEqual(applied.widgets[0].hostID,"target-local")
        XCTAssertEqual(applied.remoteHosts.count,2);XCTAssertEqual(applied.remoteHosts[0],existing)
        XCTAssertEqual(applied.displayID,42);XCTAssertFalse(applied.presentationEnabled);XCTAssertFalse(applied.showDockIcon);XCTAssertFalse(applied.previewMode)
        XCTAssertEqual(applied.completions,target.completions)
        XCTAssertEqual(applied.textScale,1.25);XCTAssertFalse(applied.snapToGrid)
        let unresolved=try setup.applying(to:target)
        XCTAssertEqual(unresolved.widgets[0].hostID,"source-local")
    }
    func testRejectsFutureVersionDuplicateWidgetIDsAndInvalidRemoteBeforeMutation() throws {
        let setup=DashboardSetup.export(document:personal(),kind:.setup)
        let data=try setup.encoded()
        let original=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var future=original;future["version"]=2
        XCTAssertThrowsError(try DashboardSetup.decode(JSONSerialization.data(withJSONObject:future)))
        var duplicate=original;let widgets=try XCTUnwrap(original["widgets"] as? [[String:Any]]);duplicate["widgets"]=[widgets[0],widgets[0]]
        XCTAssertThrowsError(try DashboardSetup.decode(JSONSerialization.data(withJSONObject:duplicate)))
        var invalid=personal();invalid.remoteHosts[0].destination="-oProxyCommand=bad"
        XCTAssertThrowsError(try DashboardSetup.export(document:invalid,kind:.setup).encoded())
        XCTAssertThrowsError(try DashboardSetup.decode(Data(repeating:32,count:16*1024*1024+1)))
    }
    func testRemoteConfigurationIDCollisionDoesNotOverwriteDestinationMachine() throws {
        var source=personal();var target=personal()
        source.remoteHosts[0].id=target.remoteHosts[0].id
        source.remoteHosts[0].destination="new-host"
        let applied=try DashboardSetup.export(document:source,kind:.setup).applying(to:target)
        XCTAssertEqual(applied.remoteHosts.count,2)
        XCTAssertEqual(Set(applied.remoteHosts.map(\.id)).count,2)
        XCTAssertEqual(applied.remoteHosts[0].destination,"minion")
        target.widgets[0].hostID="missing"
        XCTAssertEqual(try DashboardSetup.export(document:target,kind:.setup).applying(to:source).widgets[0].hostID,"missing")
    }
}
