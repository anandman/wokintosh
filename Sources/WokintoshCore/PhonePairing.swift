import Foundation

public struct PhonePairing:Codable,Equatable,Sendable {
    public let format:String
    public let version:Int
    public let endpoint:String
    public let token:String
    public var endpointURL:URL {URL(string:endpoint)!}
    public init(endpoint:String,token:String)throws {
        guard endpoint.utf8.count<=2048,let parts=URLComponents(string:endpoint),parts.scheme=="https",
              let host=parts.host,host.lowercased().hasSuffix(".ts.net"),host.count<=253,
              host.range(of:"^[A-Za-z0-9-]+(?:[.][A-Za-z0-9-]+)+$",options:.regularExpression) != nil,
              parts.user==nil,parts.password==nil,parts.query==nil,parts.fragment==nil,
              parts.port==nil || parts.port==443 || parts.port==9443,
              token.range(of:"^[A-Za-z0-9_-]{43}$",options:.regularExpression) != nil,
              parts.url != nil else {throw WidgetFeedError.invalid}
        format="dev.wokintosh.pairing";version=1;self.endpoint=endpoint;self.token=token
    }
    private enum CodingKeys:String,CodingKey {case format,version,endpoint,token}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard try c.decode(String.self,forKey:.format)=="dev.wokintosh.pairing",try c.decode(Int.self,forKey:.version)==1 else {throw WidgetFeedError.unsupported}
        try self.init(endpoint:c.decode(String.self,forKey:.endpoint),token:c.decode(String.self,forKey:.token))
    }
    public static func decode(_ data:Data)throws->PhonePairing {
        guard data.count<=4096 else {throw WidgetFeedError.oversized}
        return try JSONDecoder().decode(Self.self,from:data)
    }
    public func encoded()throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return try encoder.encode(self)
    }
}
