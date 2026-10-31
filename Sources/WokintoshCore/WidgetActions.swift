import Foundation

public enum WidgetActionKind:String,Codable,CaseIterable,Sendable {
    case none,openApplication,openURL,openAgentApp
}
public enum WidgetActionTarget:Equatable,Sendable {
    case application(bundleID:String)
    case link(URL)
}
public enum WidgetActionError:Error,LocalizedError,Equatable {
    case chooseApplication,invalidLink,unknownProvider
    public var errorDescription:String? {
        switch self {
        case .chooseApplication:return "Choose an application in this widget’s Actions settings."
        case .invalidLink:return "Enter a complete web or application link in this widget’s Actions settings."
        case .unknownProvider:return "No application has been configured for this session’s harness."
        }
    }
}
/// Each widget owns its action; older layouts and unfamiliar future kinds stay inert.
public struct WidgetAction:Codable,Equatable,Sendable {
    public var kind:WidgetActionKind = .none
    public var applicationBundleID=""
    public var applicationName=""
    public var url=""
    public var codexBundleID="com.openai.codex"
    public var codexApplicationName=""
    public var claudeBundleID="com.anthropic.claudefordesktop"
    public var claudeApplicationName=""
    public init(kind:WidgetActionKind = .none,applicationBundleID:String="",applicationName:String="",url:String="") {
        self.kind=kind;self.applicationBundleID=applicationBundleID;self.applicationName=applicationName;self.url=url
    }
    private enum CodingKeys:String,CodingKey {case kind,applicationBundleID,applicationName,url,codexBundleID,codexApplicationName,claudeBundleID,claudeApplicationName}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let raw=(try? c.decode(String.self,forKey:.kind)) ?? "none"
        kind=WidgetActionKind(rawValue:raw) ?? .none
        applicationBundleID=(try? c.decode(String.self,forKey:.applicationBundleID)) ?? ""
        applicationName=(try? c.decode(String.self,forKey:.applicationName)) ?? ""
        url=(try? c.decode(String.self,forKey:.url)) ?? ""
        codexBundleID=(try? c.decode(String.self,forKey:.codexBundleID)) ?? "com.openai.codex"
        codexApplicationName=(try? c.decode(String.self,forKey:.codexApplicationName)) ?? ""
        claudeBundleID=(try? c.decode(String.self,forKey:.claudeBundleID)) ?? "com.anthropic.claudefordesktop"
        claudeApplicationName=(try? c.decode(String.self,forKey:.claudeApplicationName)) ?? ""
    }
    public func target(provider:String?=nil)throws->WidgetActionTarget? {
        switch kind {
        case .none:return nil
        case .openApplication:return try application(applicationBundleID)
        case .openAgentApp:
            switch provider {
            case "codex":return try application(codexBundleID)
            case "claude":return try application(claudeBundleID)
            default:throw WidgetActionError.unknownProvider
            }
        case .openURL:
            let text=url.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty,text.count<=4096,text.rangeOfCharacter(from:.controlCharacters)==nil,
                  let components=URLComponents(string:text),let scheme=components.scheme?.lowercased(),
                  !["javascript","data","file","shell","vbscript"].contains(scheme),
                  let result=components.url else {throw WidgetActionError.invalidLink}
            if ["http","https"].contains(scheme),components.host?.isEmpty != false {throw WidgetActionError.invalidLink}
            return .link(result)
        }
    }
    private func application(_ value:String)throws->WidgetActionTarget {
        let id=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty,id.count<=255,id.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil else {throw WidgetActionError.chooseApplication}
        return .application(bundleID:id)
    }
}
