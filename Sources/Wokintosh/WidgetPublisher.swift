import Foundation
import Combine
import Security
import Darwin
import WokintoshCore

protocol PublisherCredentialStore {
    func load(account:String)throws->String?
    func save(_ token:String,account:String)throws
}

struct KeychainPublisherCredentials:PublisherCredentialStore {
    private func query(_ account:String)->[String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.wokintosh.phone-publisher",kSecAttrAccount as String:account]
    }
    func load(account:String)throws->String? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?
        let result=SecItemCopyMatching(q as CFDictionary,&item)
        if result==errSecItemNotFound {return nil}
        guard result==errSecSuccess,let data=item as? Data,let value=String(data:data,encoding:.utf8) else {throw WidgetFeedError.invalid}
        return value
    }
    func save(_ token:String,account:String)throws {
        let q=query(account),data=Data(token.utf8)
        let result=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result==errSecItemNotFound {
            var add=q;add[kSecValueData as String]=data;add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else {throw WidgetFeedError.invalid}
        } else if result != errSecSuccess {throw WidgetFeedError.invalid}
    }
}

struct PublisherOptions:Codable,Equatable {
    var publisherID=UUID()
    var enabled=false
    var selectedWidgetIDs=Set<UUID>()
    var endpoint=""
    var allowAgentControls=false
    init() {}
    private enum CodingKeys:String,CodingKey {case publisherID,enabled,selectedWidgetIDs,endpoint,allowAgentControls}
    init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        publisherID=try c.decode(UUID.self,forKey:.publisherID);enabled=try c.decode(Bool.self,forKey:.enabled)
        selectedWidgetIDs=try c.decode(Set<UUID>.self,forKey:.selectedWidgetIDs);endpoint=try c.decode(String.self,forKey:.endpoint)
        allowAgentControls=try c.decodeIfPresent(Bool.self,forKey:.allowAgentControls) ?? false
    }
}

@MainActor final class WidgetPublisher:ObservableObject {
    @Published private(set) var options:PublisherOptions
    @Published private(set) var status="Publishing is off"
    @Published private(set) var publishedData:Data?
    private let directory:URL
    private let credentials:PublisherCredentialStore
    private let servesNetwork:Bool
    private var server:PublisherServer?
    private var serverID:UUID?
    private var token:String?
    private var preview=false
    var onAgentControl:((AgentControlCommand)throws->Data)?
    private var settingsURL:URL {directory.appendingPathComponent("publisher-settings.json")}
    static let setupCommand="tailscale serve --bg --https=9443 --set-path=/wokintosh http://127.0.0.1:8787"

    init(directory:URL,credentials:PublisherCredentialStore=KeychainPublisherCredentials(),servesNetwork:Bool=true) {
        self.directory=directory;self.credentials=credentials;self.servesNetwork=servesNetwork
        let path=directory.appendingPathComponent("publisher-settings.json")
        if let size=try? path.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=64*1024,
           let data=try? Data(contentsOf:path),let saved=try? JSONDecoder().decode(PublisherOptions.self,from:data),saved.selectedWidgetIDs.count<=128,
           saved.endpoint.isEmpty || Self.isPublisherEndpoint(saved.endpoint) {
            options=saved;if saved.enabled {status="Waiting for agent data"}
        } else {options=PublisherOptions()}
    }
    private static func isPublisherEndpoint(_ value:String)->Bool {
        guard (try? PhonePairing(endpoint:value,token:String(repeating:"A",count:43))) != nil,
              let c=URLComponents(string:value),c.port==9443,c.path=="/wokintosh/v1/widgets" else {return false}
        return true
    }
    static func endpoint(from address:String)->String? {
        guard var c=URLComponents(string:address.trimmingCharacters(in:.whitespacesAndNewlines)),c.scheme=="https",c.user==nil,c.password==nil,c.query==nil,c.fragment==nil else {return nil}
        c.port=9443;c.path="/wokintosh/v1/widgets"
        guard let value=c.string,isPublisherEndpoint(value) else {return nil};return value
    }
    func setOptions(_ next:PublisherOptions,widgets:[DashboardWidget])throws {
        guard next.endpoint.isEmpty || Self.isPublisherEndpoint(next.endpoint) else {throw WidgetFeedError.invalid}
        var bounded=next
        let supported=Set(widgets.filter{$0.kind == .agents}.map(\.id))
        bounded.publisherID=options.publisherID
        bounded.selectedWidgetIDs=Set(next.selectedWidgetIDs.intersection(supported).sorted{$0.uuidString<$1.uuidString}.prefix(128))
        guard bounded != options else {return}
        revoke()
        options=bounded
        do {
            try persist(bounded)
            if bounded.enabled {try ensureToken();status="Waiting for agent data"} else {status="Publishing is off"}
        } catch {stopAfterFailure("Publishing stopped because its settings could not be saved.");throw error}
    }
    func removeSelections(for ids:Set<UUID>)throws {
        var next=options;next.selectedWidgetIDs.subtract(ids)
        guard next != options else {return}
        revoke();options=next
        do {try persist(next)} catch {stopAfterFailure("Publishing stopped because its selections could not be saved.");throw error}
    }
    func publish(_ widgets:[PublishedWidget],publisherName:String="Wokintosh",preview:Bool=false,at now:Date=Date(),finalize:((inout PublishedWidgetFeed)->Void)?=nil)throws {
        self.preview=preview
        guard options.enabled && !preview else {revoke();status=preview && options.enabled ? "Publishing paused in Preview" : "Publishing is off";return}
        do {
            try ensureToken()
            let selected=widgets.filter{options.selectedWidgetIDs.contains($0.id)}
            let data=try PublishedWidgetFeed(publisherID:options.publisherID,publisherName:publisherName,publishedAt:now,widgets:selected).encoded(finalize:finalize)
            publishedData=data
            if servesNetwork {
                if let server {server.update(body:data)} else {
                    let id=UUID(),next=try PublisherServer(token:token!,body:data)
                    serverID=id
                    next.onCommand={ [weak self] command in
                        await self?.performControl(command,serverID:id) ?? PublisherHTTPResult(status:503,message:"Unavailable")
                    }
                    next.onStatus={ [weak self] status in Task { @MainActor [weak self] in if self?.serverID==id {self?.status=status} } }
                    server=next;next.start()
                }
            } else {status="Ready for your iPhone or iPad"}
        } catch {revoke();status="Could not publish widgets";throw error}
    }
    private func performControl(_ command:AgentControlCommand,serverID:UUID)->PublisherHTTPResult {
        guard self.serverID==serverID,options.enabled,options.allowAgentControls,!preview,let handler=onAgentControl else {return PublisherHTTPResult(status:403,message:"Controls Disabled")}
        do {return PublisherHTTPResult(status:200,message:"OK",body:try handler(command))}
        catch AgentControlError.disabled {return PublisherHTTPResult(status:403,message:"Controls Disabled")}
        catch AgentControlError.conflict {return PublisherHTTPResult(status:409,message:"Session Changed")}
        catch {return PublisherHTTPResult(status:503,message:"Action Unconfirmed")}
    }
    func pairing()throws->PhonePairing? {
        guard options.enabled,!preview,!options.endpoint.isEmpty else {return nil}
        try ensureToken()
        return try PhonePairing(endpoint:options.endpoint,token:token!)
    }
    func rotateCredential()throws {
        revoke()
        do {
            let next=try Self.randomToken()
            try credentials.save(next,account:options.publisherID.uuidString)
            token=next;status="Access key changed. Pair your device again."
        } catch {
            var disabled=options;disabled.enabled=false;options=disabled
            try? persist(disabled);token=nil;status="Publishing stopped because the access key could not be changed."
            throw error
        }
    }
    func shutdown() {revoke()}
    private func ensureToken()throws {
        if token != nil {return}
        if let existing=try credentials.load(account:options.publisherID.uuidString) {
            guard existing.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil else {throw WidgetFeedError.invalid}
            token=existing
        } else {
            let next=try Self.randomToken();try credentials.save(next,account:options.publisherID.uuidString);token=next
        }
    }
    private static func randomToken()throws->String {
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else {throw WidgetFeedError.invalid}
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
    private func revoke() {server?.stop();server=nil;serverID=nil;publishedData=nil}
    private func stopAfterFailure(_ message:String) {
        revoke();options.enabled=false
        try? persist(options)
        status=message
    }
    private func persist(_ value:PublisherOptions)throws {
        let manager=FileManager.default
        try manager.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temporary=directory.appendingPathComponent(".publisher-"+UUID().uuidString)
        let data=try JSONEncoder().encode(value)
        guard manager.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else {throw CocoaError(.fileWriteUnknown)}
        defer {try? manager.removeItem(at:temporary)}
        guard rename(temporary.path,settingsURL.path)==0 else {throw CocoaError(.fileWriteUnknown)}
    }
    deinit {server?.stop()}
}
