import AppKit
import WokintoshCore

/// The workspace boundary is invoked only by an explicit widget/settings action.
@MainActor struct WidgetActionExecutor {
    private let launchApplication:(String) async throws->Void
    private let launchURL:(URL)->Bool
    init(launchApplication:((String) async throws->Void)?=nil,launchURL:((URL)->Bool)?=nil) {
        self.launchApplication=launchApplication ?? Self.openApplication
        self.launchURL=launchURL ?? {NSWorkspace.shared.open($0)}
    }
    func open(_ target:WidgetActionTarget) async throws {
        switch target {
        case .application(let id):try await launchApplication(id)
        case .link(let url):
            guard launchURL(url) else {throw ActionLaunchError.linkUnavailable}
        }
    }
    private static func openApplication(_ id:String) async throws {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:id) else {throw ActionLaunchError.applicationUnavailable}
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
        _=try await NSWorkspace.shared.openApplication(at:url,configuration:configuration)
    }
    private enum ActionLaunchError:Error,LocalizedError {
        case applicationUnavailable,linkUnavailable
        var errorDescription:String? {
            switch self {
            case .applicationUnavailable:return "The selected application is not installed on this Mac. Choose another app in this widget’s Actions settings."
            case .linkUnavailable:return "No application could open this link. Check it in this widget’s Actions settings."
            }
        }
    }
}
