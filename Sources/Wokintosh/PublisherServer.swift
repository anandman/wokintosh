import Foundation
@preconcurrency import Network
import WokintoshCore

enum PublisherHTTPResponse {
    static func make(request:Data,token:String,body:Data?)->Data {
        func answer(_ code:Int,_ message:String,head:Bool=false,payload:Data?=nil)->Data {
            let content=payload ?? Data(("{\"error\":\""+message+"\"}").utf8)
            let header="HTTP/1.1 \(code) \(message)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: \(content.count)\r\n\r\n"
            return Data(header.utf8)+(head ? Data() : content)
        }
        guard request.count<=16384 else {return answer(431,"Headers Too Large")}
        guard let text=String(data:request,encoding:.ascii),text.hasSuffix("\r\n\r\n") else {return answer(400,"Bad Request")}
        let lines=text.components(separatedBy:"\r\n")
        let first=(lines.first ?? "").split(separator:" ",omittingEmptySubsequences:false)
        guard first.count==3,["HTTP/1.1","HTTP/1.0"].contains(String(first[2])) else {return answer(400,"Bad Request")}
        let head=first[0]=="HEAD"
        guard first[0]=="GET" || head else {return answer(405,"Method Not Allowed")}
        var headers:[String:String]=[:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon=line.firstIndex(of:":") else {return answer(400,"Bad Request",head:head)}
            let name=String(line[..<colon]).lowercased()
            guard name.range(of:"^[a-z0-9-]+$",options:.regularExpression) != nil,headers[name]==nil else {return answer(400,"Bad Request",head:head)}
            headers[name]=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
        }
        guard headers["transfer-encoding"]==nil,headers["content-length"]==nil || headers["content-length"]=="0" else {return answer(400,"Bad Request",head:head)}
        let supplied=headers["authorization"] ?? ""
        guard supplied.prefix(7).lowercased()=="bearer ",sameToken(String(supplied.dropFirst(7)),token) else {return answer(401,"Unauthorized",head:head)}
        guard ["/v1/widgets","/wokintosh/v1/widgets"].contains(String(first[1])) else {return answer(404,"Not Found",head:head)}
        guard let body,body.count<=PublishedWidgetFeed.maximumBytes else {return answer(503,"Unavailable",head:head)}
        return answer(200,"OK",head:head,payload:body)
    }
    private static func sameToken(_ supplied:String,_ expected:String)->Bool {
        let a=Array(supplied.utf8),b=Array(expected.utf8)
        var difference=a.count ^ b.count
        for i in 0..<max(a.count,b.count) {difference |= Int((i<a.count ? a[i] : 0) ^ (i<b.count ? b[i] : 0))}
        return !b.isEmpty && difference==0
    }
}

/// The only listening socket is IPv4 loopback; Tailscale Serve terminates private
/// HTTPS separately. No filesystem paths, shell commands or mutations are served.
final class PublisherServer:@unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"dev.wokintosh.publisher")
    private let lock=NSLock()
    private let token:String
    private var body:Data?
    private var connections:[ObjectIdentifier:NWConnection]=[:]
    private var reportedReady=false
    var onReady:(@Sendable(UInt16?)->Void)?
    var onStatus:(@Sendable(String)->Void)?
    init(token:String,body:Data?,port:UInt16=8787)throws {
        guard body?.count ?? 0 <= PublishedWidgetFeed.maximumBytes,!token.isEmpty else {throw WidgetFeedError.invalid}
        self.token=token;self.body=body
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        parameters.allowLocalEndpointReuse=false
        listener=try NWListener(using:parameters)
    }
    func update(body:Data?) {
        lock.lock();defer {lock.unlock()}
        self.body=(body?.count ?? 0)<=PublishedWidgetFeed.maximumBytes ? body : nil
    }
    func start() {
        listener.stateUpdateHandler={ [weak self] state in
            guard let self else {return}
            switch state {
            case .ready:
                if !self.reportedReady {self.reportedReady=true;self.onReady?(self.listener.port?.rawValue)}
                self.onStatus?("Private publisher is running")
            case .failed:
                if !self.reportedReady {self.reportedReady=true;self.onReady?(nil)}
                self.onStatus?("Could not start the private connection. Check that port 8787 is available.")
            default:break
            }
        }
        listener.newConnectionHandler={ [weak self] connection in
            guard let self,self.connections.count<16 else {connection.cancel();return}
            self.connections[ObjectIdentifier(connection)]=connection
            connection.start(queue:self.queue)
            let timeout=DispatchWorkItem { [weak self,weak connection] in
                guard let connection else {return};connection.cancel();self?.connections.removeValue(forKey:ObjectIdentifier(connection))
            }
            self.queue.asyncAfter(deadline:.now()+5,execute:timeout)
            self.receive(connection,buffer:Data(),timeout:timeout)
        }
        listener.start(queue:queue)
    }
    private func receive(_ connection:NWConnection,buffer:Data,timeout:DispatchWorkItem) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16385-buffer.count) { [weak self] data,_,finished,error in
            guard let self else {connection.cancel();return}
            let buffer=buffer+(data ?? Data())
            if buffer.count>16384 || buffer.range(of:Data("\r\n\r\n".utf8)) != nil {
                self.lock.lock();let body=self.body;self.lock.unlock()
                let response=PublisherHTTPResponse.make(request:buffer,token:self.token,body:body)
                connection.send(content:response,completion:.contentProcessed { [weak self] _ in
                    timeout.cancel();connection.cancel();self?.connections.removeValue(forKey:ObjectIdentifier(connection))
                })
            } else if finished || error != nil {
                timeout.cancel();connection.cancel();self.connections.removeValue(forKey:ObjectIdentifier(connection))
            } else {self.receive(connection,buffer:buffer,timeout:timeout)}
        }
    }
    func stop() {
        update(body:nil);listener.cancel()
        queue.async { [self] in
            connections.values.forEach{$0.cancel()};connections.removeAll()
        }
    }
    deinit {listener.cancel()}
}
