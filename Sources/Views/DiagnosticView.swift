import SwiftUI

struct DiagnosticView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case iosLogs = "iOS Logs"
        case daemonLogs = "Daemon Logs"
        case state = "State"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .iosLogs
    @State private var iosLogs: [LogEntry] = []
    @State private var daemonLogs: [DaemonLogEntry] = []
    @State private var daemonTraceFilter = ""
    @State private var daemonError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Diagnostics", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Diagnostics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: exportJSONString()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .task {
                loadIOSLogs()
                await loadDaemonLogs()
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .iosLogs:
            List(Array(iosLogs.reversed())) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.message)
                        .font(.body)
                    Text("\(entry.timestamp.formatted(.dateTime.hour().minute().second())) • \(entry.component) • \(entry.level)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let traceId = entry.traceId, !traceId.isEmpty {
                        Text("traceId: \(traceId)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable {
                loadIOSLogs()
            }

        case .daemonLogs:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("traceId filter", text: $daemonTraceFilter)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Apply") {
                        Task { await loadDaemonLogs() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let daemonError {
                    Text(daemonError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                List(Array(daemonLogs.reversed())) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.message)
                            .font(.body)
                        Text("\(entry.timestamp) • \(entry.level)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !entry.attrs.isEmpty {
                            Text(entry.attrs.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .refreshable {
                    await loadDaemonLogs()
                }
            }

        case .state:
            List {
                keyValueRow("connectionStatus", appState.connectionStatusLabel)
                keyValueRow("activeNode", appState.activeNode?.name ?? "nil")
                keyValueRow("activeWorkspace", appState.activeWorkspace?.name ?? "nil")
                keyValueRow("currentSessionId", appState.currentSessionId ?? "nil")
                keyValueRow("isPrompting", appState.isPrompting ? "true" : "false")
                keyValueRow("messages.count", "\(appState.messages.count)")

                Section("daemonSessions") {
                    ForEach(appState.daemonSessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.sessionId)
                                .font(.body)
                            Text("\(session.state) • seq \(session.lastEventSeq)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .refreshable {
                await appState.refreshDaemonSessions()
            }
        }
    }

    @ViewBuilder
    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func loadIOSLogs() {
        iosLogs = Log.buffer.allEntries()
    }

    private func loadDaemonLogs() async {
        do {
            daemonError = nil
            let traceId = daemonTraceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            daemonLogs = try await appState.fetchDaemonLogs(
                count: 200,
                traceId: traceId.isEmpty ? nil : traceId
            )
        } catch {
            daemonError = error.localizedDescription
            daemonLogs = []
        }
    }

    private func exportJSONString() -> String {
        struct StateSnapshot: Codable {
            let connectionStatus: String
            let activeNode: String?
            let activeWorkspace: String?
            let currentSessionId: String?
            let isPrompting: Bool
            let messageCount: Int
            let daemonSessions: [DaemonSessionInfo]
        }

        struct Snapshot: Codable {
            let exportedAt: Date
            let iosLogs: [LogEntry]
            let daemonLogs: [DaemonLogEntry]
            let state: StateSnapshot
        }

        let payload = Snapshot(
            exportedAt: Date(),
            iosLogs: iosLogs,
            daemonLogs: daemonLogs,
            state: StateSnapshot(
                connectionStatus: appState.connectionStatusLabel,
                activeNode: appState.activeNode?.name,
                activeWorkspace: appState.activeWorkspace?.name,
                currentSessionId: appState.currentSessionId,
                isPrompting: appState.isPrompting,
                messageCount: appState.messages.count,
                daemonSessions: appState.daemonSessions
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
