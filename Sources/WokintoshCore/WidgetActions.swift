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
/// A saved local app fallback; collector-supplied session links take precedence.
public struct ProviderApplication: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String = "", name: String = "") { self.bundleID = bundleID; self.name = name }
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
    public var providerApplications: [String: ProviderApplication] = [:]
    public init(kind:WidgetActionKind = .none,applicationBundleID:String="",applicationName:String="",url:String="") {
        self.kind=kind;self.applicationBundleID=applicationBundleID;self.applicationName=applicationName;self.url=url
    }
    private enum CodingKeys:String,CodingKey {case kind,applicationBundleID,applicationName,url,codexBundleID,codexApplicationName,claudeBundleID,claudeApplicationName,providerApplications}
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
        providerApplications=(try? c.decode([String:ProviderApplication].self,forKey:.providerApplications)) ?? [:]
    }
    public func applicationChoice(for provider: String) -> ProviderApplication {
        switch provider {
        case "codex": return ProviderApplication(bundleID: codexBundleID, name: codexApplicationName)
        case "claude": return ProviderApplication(bundleID: claudeBundleID, name: claudeApplicationName)
        default: return providerApplications[provider] ?? ProviderApplication()
        }
    }
    public mutating func setApplicationChoice(_ choice: ProviderApplication, for provider: String) {
        switch provider {
        case "codex": codexBundleID = choice.bundleID; codexApplicationName = choice.name
        case "claude": claudeBundleID = choice.bundleID; claudeApplicationName = choice.name
        default: providerApplications[provider] = choice
        }
    }
    public func target(provider:String?=nil,session:AgentSession?=nil)throws->WidgetActionTarget? {
        switch kind {
        case .none:return nil
        case .openApplication:return try application(applicationBundleID)
        case .openAgentApp:
            if let url=session?.openURLs?.macOS?.url {return .link(url)}
            guard let provider, AgentProvider(rawValue: provider) != nil || providerApplications[provider] != nil else { throw WidgetActionError.unknownProvider }
            return try application(applicationChoice(for: provider).bundleID)
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
    public func targets(provider:String?=nil,session:AgentSession?=nil)throws->[WidgetActionTarget] {
        guard let first=try target(provider:provider,session:session) else {return []}
        var result=[first]
        if kind == .openAgentApp {
            if let url=session?.openURLs?.macOS?.fallbackURL,!result.contains(.link(url)) {result.append(.link(url))}
            if let app=try? target(provider:provider),!result.contains(app) {result.append(app)}
        }
        return result
    }
    private func application(_ value:String)throws->WidgetActionTarget {
        let id=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty,id.count<=255,id.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil else {throw WidgetActionError.chooseApplication}
        return .application(bundleID:id)
    }
}
