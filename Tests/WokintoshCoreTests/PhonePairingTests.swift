import XCTest
@testable import WokintoshCore

final class PhonePairingTests:XCTestCase {
    let token=String(repeating:"A",count:43)
    func testPairingRequiresPrivateHTTPSAndWellFormedCredential() throws {
        let p=try PhonePairing(endpoint:"https://display-host.example.ts.net/wokintosh/v1/widgets",token:token)
        XCTAssertEqual(try PhonePairing.decode(p.encoded()),p)
        XCTAssertNoThrow(try PhonePairing(endpoint:"https://display-host.example.ts.net:9443/wokintosh/v1/widgets",token:token))
        for endpoint in ["http://display-host.example.ts.net/v1/widgets","https://public.example.com/v1/widgets","https://display-host.example.ts.net.evil.com/","https://user:p@display-host.example.ts.net/","https://display-host.example.ts.net/?token=x","https://display-host.example.ts.net/#x"] {
            XCTAssertThrowsError(try PhonePairing(endpoint:endpoint,token:token),endpoint)
        }
        XCTAssertThrowsError(try PhonePairing(endpoint:"https://display-host.example.ts.net/v1/widgets",token:"short"))
        XCTAssertThrowsError(try PhonePairing.decode(Data(repeating:65,count:4097)))
    }
    func testPhoneRouteRejectsDuplicateAndUnknownKeys() {
        let a=UUID(),b=UUID()
        let base="wokintosh://session?publisher=\(a)&widget=\(b)&row=example"
        XCTAssertNotNil(PhoneRoute(url:URL(string:base)!))
        XCTAssertNil(PhoneRoute(url:URL(string:base+"&row=other")!))
        XCTAssertNil(PhoneRoute(url:URL(string:base+"&url=https://example.com")!))
    }
}
