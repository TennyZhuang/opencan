import SwiftUI

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AgentCommandStore.defaultAgentKey) private var defaultAgentID = AgentKind.claude.rawValue
    @AppStorage(AgentCommandStore.claudeCommandKey) private var claudeCommand = AgentKind.claude.defaultCommand
    @AppStorage(AgentCommandStore.codexCommandKey) private var codexCommand = AgentKind.codex.defaultCommand

    var body: some View {
        NavigationStack {
            Form {
                Section("Default Agent") {
                    Picker("Agent", selection: $defaultAgentID) {
                        ForEach(AgentKind.allCases) { agent in
                            Text(agent.displayName).tag(agent.rawValue)
                        }
                    }
                }

                Section("ACP Launch Commands") {
                    commandField(for: .claude, text: $claudeCommand)
                    commandField(for: .codex, text: $codexCommand)
                }

                Section {
                    Text("You can replace the command with custom launchers, for example npx @zed-industries/codex-acp.")
                        .font(Brutal.mono(12))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brutal.cream.ignoresSafeArea())
            .navigationTitle("Agent Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        normalizeCommandFields()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
            .onAppear {
                normalizeCommandFields()
                if AgentKind(rawValue: defaultAgentID) == nil {
                    defaultAgentID = AgentKind.claude.rawValue
                }
            }
        }
    }

    @ViewBuilder
    private func commandField(for agent: AgentKind, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.displayName)
                .font(Brutal.display(15, weight: .bold))
            TextField(agent.defaultCommand, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Brutal.mono(14))
            HStack {
                Text("Default: \(agent.defaultCommand)")
                    .font(Brutal.mono(11))
                    .foregroundStyle(.black.opacity(0.5))
                Spacer()
                Button("Reset") {
                    text.wrappedValue = agent.defaultCommand
                }
                .font(Brutal.mono(11, weight: .bold))
                .foregroundStyle(.black)
            }
        }
    }

    private func normalizeCommandFields() {
        claudeCommand = normalize(claudeCommand, fallback: AgentKind.claude.defaultCommand)
        codexCommand = normalize(codexCommand, fallback: AgentKind.codex.defaultCommand)
    }

    private func normalize(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
