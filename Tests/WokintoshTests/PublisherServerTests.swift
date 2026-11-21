import Foundation
import XCTest
@testable import Wokintosh

final class PublisherServerTests:XCTestCase {
    let token=String(repeating:"A",count:43)
    let body=Data("{\"widgets\":[]}".utf8)
    func request(_ line:String="GET /v1/widgets HTTP/1.1",headers:String?=nil)->Data {
        Data((line+"\r\nHost: localhost\r\n"+(headers ?? "Authorization: Bearer "+token)+"\r\n\r\n").utf8)
    }
    func response(_ data:Data)->String {String(decoding:PublisherHTTPResponse.make(request:data,token:token,body:body),as:UTF8.self)}
    func testAuthenticationAndReadOnlyRoutes() {
        XCTAssertTrue(response(request()).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response(request(headers:"Authorization: Bearer wrong")).hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(response(request(headers:"X-Other: value")).hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(response(request("POST /v1/widgets HTTP/1.1")).hasPrefix("HTTP/1.1 405"))
        XCTAssertTrue(response(request("GET /private/file HTTP/1.1")).hasPrefix("HTTP/1.1 404"))
        XCTAssertTrue(response(request()).contains("Cache-Control: no-store"))
        XCTAssertFalse(response(request()).contains(token))
    }
    func testHeadHasTheRealLengthAndNoBodyAndDuplicateAuthIsRejected() {
        let result=response(request("HEAD /v1/widgets HTTP/1.1"))
        XCTAssertTrue(result.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(result.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(response(request(headers:"Authorization: Bearer \(token)\r\nAuthorization: Bearer \(token)")).hasPrefix("HTTP/1.1 400"))
        XCTAssertTrue(response(Data(repeating:65,count:16385)).hasPrefix("HTTP/1.1 431"))
        XCTAssertTrue(response(request("GET /v1/widgets?token=\(token) HTTP/1.1")).hasPrefix("HTTP/1.1 404"))
    }
    func testRealLoopbackListenerRequiresTheToken() async throws {
        let server=try PublisherServer(token:token,body:body,port:0)
        let port:UInt16?=await withCheckedContinuation {continuation in
            server.onReady={continuation.resume(returning:$0)};server.start()
        }
        defer {server.stop()}
        let chosen=try XCTUnwrap(port)
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(chosen)/v1/widgets")!)
        request.timeoutInterval=3
        let (_,unauthorized)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode,401)
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        let (received,authorized)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode,200)
        XCTAssertEqual(received,body)
    }
}
