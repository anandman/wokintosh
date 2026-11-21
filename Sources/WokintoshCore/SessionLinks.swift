import Foundation

/// Navigation supplied by the collector. Primary/fallback describe navigation,
/// never a command, prompt, approval or mutable session operation.
public struct SessionOpenTarget:Codable,Equatable,Sendable {
    public var primary:String
    public var fallback:String?
    public var fallbackLabel:String?
    public init(primary:String,fallback:String?=nil,fallbackLabel:String?=nil) {self.primary=primary;self.fallback=fallback;self.fallbackLabel=Self.validLabel(fallbackLabel)}
    public var url:URL? {Self.validURL(primary)}
    public var fallbackURL:URL? {fallback.flatMap(Self.validURL)}
    public static func validURL(_ value:String)->URL? {
        guard !value.isEmpty,value.utf8.count<=4096,value.rangeOfCharacter(from:.controlCharacters)==nil,
              let parts=URLComponents(string:value),let scheme=parts.scheme?.lowercased(),
              ["https","claude","codex"].contains(scheme),parts.user==nil,parts.password==nil,
              let host=parts.host,!host.isEmpty,let url=parts.url else {return nil}
        return url
    }
    private static func validLabel(_ value:String?)->String? {
        guard let value,!value.isEmpty,value.count<=80,value.rangeOfCharacter(from:.controlCharacters)==nil else {return nil}
        return value
    }
    private enum CodingKeys:String,CodingKey {case primary,fallback,fallbackLabel}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let value=try c.decode(String.self,forKey:.primary)
        guard Self.validURL(value) != nil else {
            throw DecodingError.dataCorruptedError(forKey:.primary,in:c,debugDescription:"Invalid session navigation target")
        }
        fallbackLabel=Self.validLabel(try? c.decode(String.self,forKey:.fallbackLabel))
        primary=value
        fallback=(try? c.decode(String.self,forKey:.fallback)).flatMap{Self.validURL($0) == nil ? nil : $0}
    }
}

public struct SessionOpenURLs:Codable,Equatable,Sendable {
    public var macOS:SessionOpenTarget?
    public var iOS:SessionOpenTarget?
    public init(macOS:SessionOpenTarget?=nil,iOS:SessionOpenTarget?=nil) {self.macOS=macOS;self.iOS=iOS}
    private enum CodingKeys:String,CodingKey {case macOS,iOS}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        macOS=try? c.decode(SessionOpenTarget.self,forKey:.macOS)
        iOS=try? c.decode(SessionOpenTarget.self,forKey:.iOS)
    }
}
