import Foundation

public enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, antigravity, opencode
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        }
    }
    public var isUntested: Bool { self == .antigravity || self == .opencode }
    public var title: String { name + (isUntested ? " (Untested)" : "") }
    public var symbol: String { self == .claude ? "sparkle" : "terminal" }
    public static func name(for value: String) -> String { Self(rawValue: value)?.name ?? "Agent" }
    public static func title(for value: String) -> String { Self(rawValue: value)?.title ?? "Agent" }
}

public extension AgentSession {
    var providerTitle: String { AgentProvider.title(for: provider) }
    var hasUntestedProvider: Bool { AgentProvider(rawValue: provider)?.isUntested == true }
    var unavailableMobileLinkMessage: String {
        switch AgentProvider(rawValue: provider) {
        case .antigravity:
            return "No verified mobile session link is available. Antigravity App and CLI need Remote Control enabled and a captured or configured conversation link. This integration is Untested."
        case .opencode:
            return "No verified mobile session link is available. Configure this session’s authenticated OpenCode web link on its source machine. This integration is Untested."
        case .claude:
            return "No mobile link is available yet. Update this machine’s Wokintosh collector and connect Claude Remote Control."
        default:
            return "No mobile link is available yet. Update this machine’s Wokintosh collector and check the provider’s session-link setup."
        }
    }
}
