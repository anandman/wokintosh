import Foundation
import Darwin

/// A short cross-process transaction for the app and WidgetKit extension.
/// Never hold this lock while fetching or waiting on another task.
struct PhoneRepositoryCoordinator {
    let directory:URL
    private var generationURL:URL {directory.appendingPathComponent("pairing-generation")}
    private var requestURL:URL {directory.appendingPathComponent("latest-request")}
    func withLock<T>(_ body:()throws->T)throws->T {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor=Darwin.open(directory.appendingPathComponent("pairing.lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer {Darwin.close(descriptor)}
        while flock(descriptor,LOCK_EX) != 0 {
            if errno != EINTR {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        }
        defer {flock(descriptor,LOCK_UN)}
        return try body()
    }
    func generation()throws->UUID {
        if let data=try? Data(contentsOf:generationURL),let text=String(data:data,encoding:.utf8),let id=UUID(uuidString:text) {return id}
        return try advanceGeneration()
    }
    @discardableResult func advanceGeneration()throws->UUID {try writeID(to:generationURL)}
    func beginRequest()throws->UUID {try writeID(to:requestURL)}
    func latestRequest()->UUID? {
        guard let data=try? Data(contentsOf:requestURL),let text=String(data:data,encoding:.utf8) else {return nil}
        return UUID(uuidString:text)
    }
    private func writeID(to url:URL)throws->UUID {
        let id=UUID()
        try Data(id.uuidString.utf8).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
        return id
    }
}
