import Foundation
@preconcurrency import Dispatch
@preconcurrency import Network
import WokintoshCore

struct PublisherHTTPError:Error {let status:Int;let message:String}
struct PublisherHTTPRequest:Sendable {
    let method:String
    let path:String
    let headers:[String:String]
    let body:Data
    static func parse(_ bytes:Data)throws->Self? {
        guard let boundary=bytes.range(of:Data("\r\n\r\n".utf8)) else {
            if bytes.count>16384 {throw PublisherHTTPError(status:431,message:"Headers Too Large")};return nil
        }
        guard boundary.upperBound<=16384 else {throw PublisherHTTPError(status:431,message:"Headers Too Large")}
        guard let text=String(data:bytes[..<boundary.lowerBound],encoding:.ascii) else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        let lines=text.components(separatedBy:"\r\n"),first=(lines.first ?? "").split(separator:" ",omittingEmptySubsequences:false)
        guard first.count==3,["HTTP/1.1","HTTP/1.0"].contains(String(first[2])) else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        let method=String(first[0]),path=String(first[1])
        guard ["GET","HEAD","POST"].contains(method) else {throw PublisherHTTPError(status:405,message:"Method Not Allowed")}
        var headers:[String:String]=[:]
        for line in lines.dropFirst() {
            guard let colon=line.firstIndex(of:":") else {throw PublisherHTTPError(status:400,message:"Bad Request")}
            let name=String(line[..<colon]).lowercased()
            guard name.range(of:"^[a-z0-9-]+$",options:.regularExpression) != nil,headers[name]==nil else {throw PublisherHTTPError(status:400,message:"Bad Request")}
            headers[name]=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
        }
        guard headers["transfer-encoding"]==nil else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        var length=0
        if let value=headers["content-length"] {
            guard value.range(of:"^(0|[1-9][0-9]{0,4})$",options:.regularExpression) != nil,let count=Int(value),count<=16384 else {throw PublisherHTTPError(status:400,message:"Bad Request")}
            length=count
        }
        if method=="POST" {
            guard ["/v1/agent-actions","/wokintosh/v1/agent-actions"].contains(path) else {throw PublisherHTTPError(status:405,message:"Method Not Allowed")}
            guard length>0,headers["content-type"]?.lowercased()=="application/json" else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        } else if length != 0 {throw PublisherHTTPError(status:400,message:"Bad Request")}
        let body=Data(bytes[boundary.upperBound...])
        guard body.count<=length else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        if body.count<length {return nil}
        return Self(method:method,path:path,headers:headers,body:body)
    }
}
struct PublisherHTTPResult:Sendable {
    let status:Int
    let message:String
    var body:Data?=nil
    var data:Data {PublisherHTTPResponse.answer(status,message,payload:body)}
}
enum PublisherHTTPResponse {
    static func answer(_ code:Int,_ message:String,head:Bool=false,payload:Data?=nil)->Data {
        let content=payload ?? Data(("{\"error\":\""+message+"\"}").utf8)
        let header="HTTP/1.1 \(code) \(message)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: \(content.count)\r\n\r\n"
        return Data(header.utf8)+(head ? Data() : content)
    }
    static func make(request:Data,token:String,body:Data?)->Data {
        do {
            guard let parsed=try PublisherHTTPRequest.parse(request) else {return answer(400,"Bad Request")}
            guard parsed.method != "POST" else {return answer(405,"Method Not Allowed")}
            let head=parsed.method=="HEAD"
            guard authorized(parsed,token:token) else {return answer(401,"Unauthorized",head:head)}
            guard ["/v1/widgets","/wokintosh/v1/widgets"].contains(parsed.path) else {return answer(404,"Not Found",head:head)}
            guard let body,body.count<=PublishedWidgetFeed.maximumBytes else {return answer(503,"Unavailable",head:head)}
            return answer(200,"OK",head:head,payload:body)
        } catch let e as PublisherHTTPError {return answer(e.status,e.message)}
        catch {return answer(400,"Bad Request")}
    }
    static func command(request:Data,token:String)throws->AgentControlCommand {
        guard let parsed=try PublisherHTTPRequest.parse(request),parsed.method=="POST" else {throw PublisherHTTPError(status:400,message:"Bad Request")}
        guard authorized(parsed,token:token) else {throw PublisherHTTPError(status:401,message:"Unauthorized")}
        do {return try AgentControlCommand.decode(parsed.body)} catch {throw PublisherHTTPError(status:400,message:"Bad Request")}
    }
    private static func authorized(_ parsed:PublisherHTTPRequest,token:String)->Bool {
        let supplied=parsed.headers["authorization"] ?? ""
        guard supplied.prefix(7).lowercased()=="bearer " else {return false}
        let a=Array(supplied.dropFirst(7).utf8),b=Array(token.utf8)
        var difference=a.count ^ b.count
        for i in 0..<max(a.count,b.count) {difference |= Int((i<a.count ? a[i] : 0) ^ (i<b.count ? b[i] : 0))}
        return !b.isEmpty && difference==0
    }
}

/// The only listening socket is IPv4 loopback; Tailscale Serve terminates private
/// HTTPS separately. Commands are limited to receipt-checked Agent bookkeeping.
final class PublisherServer:@unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"dev.wokintosh.publisher")
    private let lock=NSLock()
    private let token:String
    private var body:Data?
    private var connections:[ObjectIdentifier:NWConnection]=[:]
    private var reportedReady=false
    var onCommand:(@Sendable(AgentControlCommand)async->PublisherHTTPResult)?
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
    private func send(_ response:Data,to connection:NWConnection,timeout:DispatchWorkItem) {
        connection.send(content:response,completion:.contentProcessed { [weak self] _ in
            timeout.cancel();connection.cancel();self?.connections.removeValue(forKey:ObjectIdentifier(connection))
        })
    }
    private func receive(_ connection:NWConnection,buffer:Data,timeout:DispatchWorkItem) {
        connection.receive(minimumIncompleteLength:1,maximumLength:max(1,32769-buffer.count)) { [weak self] data,_,finished,error in
            guard let self else {connection.cancel();return}
            let buffer=buffer+(data ?? Data())
            do {
                guard buffer.count<=32768 else {throw PublisherHTTPError(status:413,message:"Request Too Large")}
                if let parsed=try PublisherHTTPRequest.parse(buffer) {
                    if parsed.method=="POST" {
                        let command=try PublisherHTTPResponse.command(request:buffer,token:self.token)
                        let callback=self.onCommand
                        Task {
                            let result=await callback?(command) ?? PublisherHTTPResult(status:403,message:"Controls Disabled")
                            self.queue.async {self.send(result.data,to:connection,timeout:timeout)}
                        }
                    } else {
                        self.lock.lock();let body=self.body;self.lock.unlock()
                        self.send(PublisherHTTPResponse.make(request:buffer,token:self.token,body:body),to:connection,timeout:timeout)
                    }
                } else if finished || error != nil {
                    self.send(PublisherHTTPResponse.answer(400,"Bad Request"),to:connection,timeout:timeout)
                } else {self.receive(connection,buffer:buffer,timeout:timeout)}
            } catch let e as PublisherHTTPError {self.send(PublisherHTTPResponse.answer(e.status,e.message),to:connection,timeout:timeout)}
            catch {self.send(PublisherHTTPResponse.answer(400,"Bad Request"),to:connection,timeout:timeout)}
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
