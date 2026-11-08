import XCTest
import WokintoshCore
@testable import Wokintosh

@MainActor final class SetupStoreTests:XCTestCase {
    func testImportPublishesOnlyAfterPersistenceAndBacksUpUnsavedChanges() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=DashboardStore(dataDirectory:directory)
        store.document.textScale=1.15;store.document.displayID=43
        let current=store.document
        var imported=DashboardDocument(widgets:[Widget(kind:.clock,frame:WidgetFrame(x:0,y:0,width:0.5,height:0.5))]);imported.textScale=1.4
        let backup=try store.applySetup(DashboardSetup.export(document:imported,kind:.setup))
        XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:backup)),current)
        XCTAssertEqual(store.document.widgets.map(\.kind),[.clock]);XCTAssertEqual(store.document.displayID,43)
        XCTAssertEqual(store.selectedID,store.document.widgets.first?.id)
        XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:directory.appendingPathComponent("layout.json"))),store.document)
    }
    func testFailedCommitLeavesPublishedDocumentAndSelectionUntouched() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=DashboardStore(dataDirectory:directory)
        let current=store.document;let selected=store.selectedID
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("layout.json"),withIntermediateDirectories:true)
        var incoming=DashboardDocument(widgets:[]);incoming.textScale=1.6
        XCTAssertThrowsError(try store.applySetup(DashboardSetup.export(document:incoming,kind:.template)))
        XCTAssertEqual(store.document,current);XCTAssertEqual(store.selectedID,selected)
    }
}
