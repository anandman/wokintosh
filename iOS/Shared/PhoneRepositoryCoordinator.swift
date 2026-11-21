import Foundation
import Darwin
import WokintoshCore

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
    @discardableResult func advanceGeneration()throws->UUID {
        try? FileManager.default.removeItem(at:leaseURL);try? setActionMessage(nil)
        return try writeID(to:generationURL)
    }
    func beginRequest()throws->UUID {try writeID(to:requestURL)}
    func latestRequest()->UUID? {
        guard let data=try? Data(contentsOf:requestURL),let text=String(data:data,encoding:.utf8) else {return nil}
        return UUID(uuidString:text)
    }
    private struct ActionLease:Codable {let id:UUID;let until:Date}
    private var leaseURL:URL {directory.appendingPathComponent("agent-action-lease.json")}
    private var outcomeURL:URL {directory.appendingPathComponent("agent-action-error")}
    func actionInProgress()->Bool {
        guard let data=try? Data(contentsOf:leaseURL),let lease=try? JSONDecoder().decode(ActionLease.self,from:data) else {return false}
        return lease.until>Date()
    }
    func beginAction(_ id:UUID)throws {
        guard !actionInProgress() else {throw WokintoshCore.AgentControlError.busy}
        try JSONEncoder().encode(ActionLease(id:id,until:Date().addingTimeInterval(30))).write(to:leaseURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:leaseURL.path)
    }
    func endAction(_ id:UUID) {
        guard let data=try? Data(contentsOf:leaseURL),let lease=try? JSONDecoder().decode(ActionLease.self,from:data),lease.id==id else {return}
        try? FileManager.default.removeItem(at:leaseURL)
    }
    func actionMessage()->String? {
        guard let data=try? Data(contentsOf:outcomeURL),data.count<=1024 else {return nil};return String(data:data,encoding:.utf8)
    }
    func setActionMessage(_ message:String?)throws {
        if let message {try Data(message.prefix(200).utf8).write(to:outcomeURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:outcomeURL.path)}
        else {try? FileManager.default.removeItem(at:outcomeURL)}
    }
    private func writeID(to url:URL)throws->UUID {
        let id=UUID()
        try Data(id.uuidString.utf8).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600,.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.path)
        return id
    }
}
