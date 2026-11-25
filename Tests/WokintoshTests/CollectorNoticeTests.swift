import Foundation
import XCTest
@testable import WokintoshCore
@testable import Wokintosh

@MainActor final class CollectorNoticeTests:XCTestCase {
    func testBundledFingerprintIgnoresOnlyInstallerPinnedInterpreter() throws {
        let first=try XCTUnwrap(BundledCollector.info(source:Data("#!/usr/bin/env python3\nCOLLECTOR_VERSION = '2.0.1'\n".utf8)))
        let pinned=try XCTUnwrap(BundledCollector.info(source:Data("#!/opt/python3\nCOLLECTOR_VERSION = '2.0.1'\n".utf8)))
        XCTAssertEqual(first,pinned)
        XCTAssertEqual(first.version,"2.0.1")
        let changed=try XCTUnwrap(BundledCollector.info(source:Data("#!/opt/python3\nCOLLECTOR_VERSION = '2.0.1'\n# changed behavior\n".utf8)))
        XCTAssertNotEqual(first.revision,changed.revision)
        XCTAssertNil(BundledCollector.info(source:Data("unknown source".utf8)))
    }
    func testOnlyConnectedEnabledRemoteUpdatesCountAndPreviewDoesNotNotify() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=DashboardStore(dataDirectory:directory)
        store.document.previewMode=false
        let bundled=CollectorInfo(version:"2.0.1",revision:String(repeating:"a",count:64))
        store.bundledCollectorInfo=bundled
        for (index,enabled,connected,info) in [
            (0,true,true,Optional<CollectorInfo>.none),
            (1,true,true,CollectorInfo(version:"2.0.0",revision:String(repeating:"b",count:64))),
            (2,true,true,bundled),
            (3,true,false,Optional<CollectorInfo>.none),
            (4,false,true,Optional<CollectorInfo>.none),
            (5,true,true,CollectorInfo(version:"2.1.0",revision:String(repeating:"b",count:64)))] {
            var host=RemoteHost(name:"Fixture \(index)",destination:"fixture-\(index)",collectorPath:"~/bin/agent");host.enabled=enabled
            store.document.remoteHosts.append(host)
            let snapshot=Snapshot(schemaVersion:1,host:HostInfo(id:"\(index)",name:"Fixture",platform:"linux"),generatedAt:Date(),sessions:[],system:SystemReading(),collector:info)
            store.feeds[host.id.uuidString]=FeedStatus(name:host.name,snapshot:snapshot,error:connected ? nil : "Offline")
        }
        XCTAssertEqual(store.collectorUpdateCount,2)
        XCTAssertNil(store.collectorUpdate(for:FeedStatus(name:"Offline",error:"Offline")))
        store.document.previewMode=true
        XCTAssertEqual(store.collectorUpdateCount,0)
    }
}
