import Foundation
import XCTest
@testable import WokintoshCore
@testable import Wokintosh

@MainActor final class CollectorPopupTests:XCTestCase {
    private let bundled=CollectorInfo(version:"2.0.1",revision:String(repeating:"a",count:64))
    private func store(at directory:URL)->DashboardStore {
        let store=DashboardStore(dataDirectory:directory)
        store.document.previewMode=false;store.bundledCollectorInfo=bundled
        return store
    }
    private func connect(_ store:DashboardStore,host:RemoteHost,info:CollectorInfo?=nil,online:Bool=true) {
        if !store.document.remoteHosts.contains(where:{$0.id==host.id}) {store.document.remoteHosts.append(host)}
        let snapshot=Snapshot(schemaVersion:1,host:HostInfo(id:host.id.uuidString,name:host.name,platform:"linux"),generatedAt:Date(),sessions:[],system:SystemReading(),collector:info)
        store.feeds[host.id.uuidString]=FeedStatus(name:host.name,snapshot:snapshot,error:online ? nil : "Offline")
    }
    func testPopupAppearsOnceForAnUpdateAcrossPollingAndAppRelaunch() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let host=RemoteHost(name:"Build Mac",destination:"build",collectorPath:"~/bin/agent")
        let first=store(at:directory)
        connect(first,host:host)
        var messages:[AppMessage]=[];first.presentMessage={messages.append($0)}
        first.notifyCollectorUpdates();first.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,1)
        XCTAssertEqual(messages.first?.action,.reviewCollectorUpdates)
        XCTAssertTrue(try XCTUnwrap(messages.first).message.contains("Build Mac"))
        var opened=0;first.showSettings={opened+=1}
        first.respondToAppMessage(try XCTUnwrap(messages.first),response:.alertSecondButtonReturn)
        XCTAssertEqual(opened,0)
        let reopened=store(at:directory)
        connect(reopened,host:host)
        reopened.presentMessage={messages.append($0)}
        reopened.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,1)
        // A changed bundled collector is a new update worth notifying about.
        reopened.bundledCollectorInfo=CollectorInfo(version:"2.0.2",revision:String(repeating:"b",count:64))
        reopened.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,2)
    }
    func testQueuedPopupIsNotPermanentlyAcknowledgedBeforeTheUserSeesIt() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let host=RemoteHost(name:"Build Mac",destination:"build",collectorPath:"~/bin/agent")
        var messages:[AppMessage]=[]
        let first=store(at:directory);connect(first,host:host);first.presentMessage={messages.append($0)}
        first.notifyCollectorUpdates()
        first.respondToAppMessage(try XCTUnwrap(messages.first),response:.abort)
        let reopened=store(at:directory);connect(reopened,host:host);reopened.presentMessage={messages.append($0)}
        reopened.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,2)
    }
    func testNewlyDiscoveredMachineGetsAPopupWithoutRepeatingAcknowledgedMachines() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=store(at:directory)
        connect(store,host:RemoteHost(name:"First Mac",destination:"first",collectorPath:"~/bin/agent"))
        var messages:[AppMessage]=[];store.presentMessage={messages.append($0)}
        store.notifyCollectorUpdates()
        connect(store,host:RemoteHost(name:"Second Mac",destination:"second",collectorPath:"~/bin/agent"))
        store.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,2)
        XCTAssertTrue(messages[1].message.contains("Second Mac"))
        XCTAssertFalse(messages[1].message.contains("First Mac"))
    }
    func testPreviewOfflineAndMissingPresenterDoNotConsumeTheNotification() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=store(at:directory)
        let host=RemoteHost(name:"Build Mac",destination:"build",collectorPath:"~/bin/agent")
        connect(store,host:host,online:false)
        var messages:[AppMessage]=[];store.presentMessage={messages.append($0)}
        store.notifyCollectorUpdates();XCTAssertTrue(messages.isEmpty)
        connect(store,host:host)
        store.document.previewMode=true;store.notifyCollectorUpdates();XCTAssertTrue(messages.isEmpty)
        store.document.previewMode=false;store.presentMessage=nil;store.notifyCollectorUpdates()
        store.presentMessage={messages.append($0)};store.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,1)
    }
    func testPopupIncludesLocalObserverUpdatesAndReviewOpensMachines() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=store(at:directory)
        var local=bundled;local.observerStatus="updateAvailable"
        let snapshot=Snapshot(schemaVersion:1,host:HostInfo(id:"local",name:"Fixture",platform:"macos"),generatedAt:Date(),sessions:[],system:SystemReading(),collector:local)
        store.feeds["local"]=FeedStatus(name:"This Mac",snapshot:snapshot)
        var messages:[AppMessage]=[];store.presentMessage={messages.append($0)}
        store.notifyCollectorUpdates()
        XCTAssertEqual(messages.count,1)
        XCTAssertEqual(store.collectorUpdateCount,1)
        XCTAssertTrue(try XCTUnwrap(messages.first).message.contains("This Mac"))
        var opened=0;store.showSettings={opened+=1}
        store.respondToAppMessage(try XCTUnwrap(messages.first),response:.alertFirstButtonReturn)
        XCTAssertEqual(store.settingsTab,.machines);XCTAssertEqual(opened,1)
    }
}
