import XCTest
import WokintoshCore
@testable import Wokintosh

final class PublisherCommandHTTPTests:XCTestCase {
    func packet(_ body:Data,headers:String="",token:String="secret")->Data {
        Data("POST /wokintosh/v1/agent-actions HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\(headers)\r\n".utf8)+body
    }
    func testCommandWaitsForWholeBodyAndChecksAuthentication()throws {
        let c=AgentControlCommand(publisherID:UUID(),widgetID:UUID(),rowID:"host:codex:session",action:.reviewDone,revision:String(repeating:"a",count:64))
        let data=packet(try c.encoded())
        XCTAssertNil(try PublisherHTTPRequest.parse(data.dropLast()))
        let parsed=try PublisherHTTPResponse.command(request:data,token:"secret")
        XCTAssertEqual(parsed.id,c.id)
        XCTAssertThrowsError(try PublisherHTTPResponse.command(request:packet(try c.encoded(),token:"wrong"),token:"secret"))
    }
    func testAmbiguousFramingAndOversizeBodyAreRejected()throws {
        for headers in ["Content-Length: 2\r\n","Transfer-Encoding: chunked\r\n","Content-Length: -1\r\n"] {
            XCTAssertThrowsError(try PublisherHTTPRequest.parse(packet(Data("{}".utf8),headers:headers)))
        }
        XCTAssertThrowsError(try PublisherHTTPRequest.parse(packet(Data(repeating:0,count:16385))))
        XCTAssertThrowsError(try PublisherHTTPRequest.parse(packet(Data("{}".utf8))+Data("extra".utf8)))
    }
}
