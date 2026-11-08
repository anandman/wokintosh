import XCTest
@testable import WokintoshCore

final class SetupPersistenceTests:XCTestCase {
    func testBackupContainsUnsavedCurrentDocumentAndCommitContainsImportedLayout() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let current=DashboardDocument.defaultLayout
        var imported=current;imported.textScale=1.4
        let backup=try SetupPersistence.importDocument(imported,replacing:current,in:directory)
        XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:backup)),current)
        XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:directory.appendingPathComponent("layout.json"))),imported)
    }
    func testBackupFailureDoesNotChangeSavedLayout() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("layout.json")
        let current=DashboardDocument.defaultLayout
        let original=try JSONEncoder().encode(current);try original.write(to:file)
        XCTAssertThrowsError(try SetupPersistence.importDocument(current,replacing:current,in:directory,write:{_,_ in throw CocoaError(.fileWriteNoPermission)}))
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testCommitFailureLeavesOriginalFileAndRecoverableBackup() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("layout.json")
        let current=DashboardDocument.defaultLayout
        let original=try JSONEncoder().encode(current);try original.write(to:file)
        XCTAssertThrowsError(try SetupPersistence.importDocument(current,replacing:current,in:directory,write:{data,url in
            if url.lastPathComponent=="layout.json" {throw CocoaError(.fileWriteNoPermission)}
            try data.write(to:url,options:.atomic)
        }))
        XCTAssertEqual(try Data(contentsOf:file),original)
        let backups=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix("layout-backup-")}
        XCTAssertEqual(backups.count,1);XCTAssertEqual(try JSONDecoder().decode(DashboardDocument.self,from:Data(contentsOf:backups[0])),current)
    }
}
