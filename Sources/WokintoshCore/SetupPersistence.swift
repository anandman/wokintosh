import Foundation

public enum SetupPersistence {
    /// Back up the current in-memory document before committing. Callers publish only on success.
    @discardableResult public static func importDocument(_ imported:DashboardDocument,replacing current:DashboardDocument,
                                                         in directory:URL,at now:Date=Date(),
                                                         write:(Data,URL)throws->Void = {try $0.write(to:$1,options:.atomic)}) throws -> URL {
        let encoder=JSONEncoder()
        let currentData=try encoder.encode(current)
        let importedData=try encoder.encode(imported)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat="yyyy-MM-dd-HHmmss"
        let backup=directory.appendingPathComponent("layout-backup-\(formatter.string(from:now))-\(UUID().uuidString).json")
        try write(currentData,backup)
        try write(importedData,directory.appendingPathComponent("layout.json"))
        return backup
    }
}
