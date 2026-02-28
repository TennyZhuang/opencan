import Foundation

/// Built-in ACP agent integrations.
enum AgentKind: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var defaultCommand: String {
        switch self {
        case .claude: "claude-agent-acp"
        case .codex: "codex-acp"
        }
    }
}

enum AgentCommandStore {
    static let claudeCommandKey = "agent.command.claude"
    static let codexCommandKey = "agent.command.codex"
    static let defaultAgentKey = "agent.default"

    static func command(for agent: AgentKind, defaults: UserDefaults = .standard) -> String {
        let key = storageKey(for: agent)
        let configured = defaults.string(forKey: key)?.trimmedNonEmpty
        return configured ?? agent.defaultCommand
    }

    static func command(forAgentID agentID: String?, defaults: UserDefaults = .standard) -> String {
        guard let agent = agent(forAgentID: agentID) else {
            return AgentKind.claude.defaultCommand
        }
        return command(for: agent, defaults: defaults)
    }

    /// Best-effort mapping from a raw launcher command back to a built-in agent.
    static func inferAgent(fromCommand launcherCommand: String?) -> AgentKind? {
        guard let raw = launcherCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if raw.contains("codex-acp") { return .codex }
        if raw.contains("claude-agent-acp") { return .claude }

        for agent in AgentKind.allCases {
            if raw == agent.defaultCommand || raw == command(for: agent) {
                return agent
            }
        }
        return nil
    }

    static func defaultAgent(defaults: UserDefaults = .standard) -> AgentKind {
        guard let raw = defaults.string(forKey: defaultAgentKey),
              let agent = AgentKind(rawValue: raw) else {
            return .claude
        }
        return agent
    }

    static func storageKey(for agent: AgentKind) -> String {
        switch agent {
        case .claude: claudeCommandKey
        case .codex: codexCommandKey
        }
    }

    static func agent(forAgentID agentID: String?) -> AgentKind? {
        guard let agentID else { return nil }
        return AgentKind(rawValue: agentID)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
