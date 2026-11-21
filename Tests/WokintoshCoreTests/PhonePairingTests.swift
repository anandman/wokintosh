import XCTest
@testable import WokintoshCore

final class PhonePairingTests:XCTestCase {
    let token=String(repeating:"A",count:43)
    func testPairingRequiresPrivateHTTPSAndWellFormedCredential() throws {
        let p=try PhonePairing(endpoint:"https://display.example.ts.net/wokintosh/v1/widgets",token:token)
        XCTAssertEqual(try PhonePairing.decode(p.encoded()),p)
        XCTAssertNoThrow(try PhonePairing(endpoint:"https://display.example.ts.net:9443/wokintosh/v1/widgets",token:token))
        for endpoint in ["http://display.example.ts.net/v1/widgets","https://public.example.com/v1/widgets","https://display.example.ts.net.evil.com/","https://user:p@display.example.ts.net/","https://display.example.ts.net/?token=x","https://display.example.ts.net/#x"] {
            XCTAssertThrowsError(try PhonePairing(endpoint:endpoint,token:token),endpoint)
        }
        XCTAssertThrowsError(try PhonePairing(endpoint:"https://display.example.ts.net/v1/widgets",token:"short"))
        XCTAssertThrowsError(try PhonePairing.decode(Data(repeating:65,count:4097)))
    }
    func testPairingCodeBytesRemainStableAcrossDashboardRefreshes() throws {
        let pairing=try PhonePairing(endpoint:"https://display.example.ts.net:9443/wokintosh/v1/widgets",token:token)
        let encoded=try (0..<64).map{_ in try pairing.encoded()}
        XCTAssertEqual(Set(encoded).count,1,"An unchanged pairing must render the same QR code")
        XCTAssertEqual(try PhonePairing.decode(encoded[0]),pairing)
        let rotated=try PhonePairing(endpoint:pairing.endpoint,token:String(repeating:"B",count:43))
        XCTAssertNotEqual(try rotated.encoded(),encoded[0])
    }
    func testPhoneRouteRejectsDuplicateAndUnknownKeys() {
        let a=UUID(),b=UUID()
        let base="wokintosh://session?publisher=\(a)&widget=\(b)&row=example"
        XCTAssertNotNil(PhoneRoute(url:URL(string:base)!))
        XCTAssertNil(PhoneRoute(url:URL(string:base+"&row=other")!))
        XCTAssertNil(PhoneRoute(url:URL(string:base+"&url=https://example.com")!))
    }
}
