import SwiftUI

struct DiagnosticView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private struct SharedBundle: Identifiable {
        let id = UUID()
        let url: URL
    }

    private enum Tab: String, CaseIterable, Identifiable {
        case iosLogs = "iOS Logs"
        case daemonLogs = "Daemon Logs"
        case state = "State"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .iosLogs
    @State private var iosLogs: [LogEntry] = []
    @State private var iosLogMetadata = Log.diagnosticsMetadata()
    @State private var daemonLogs: [DaemonLogEntry] = []
    @State private var daemonLogMetadata: LogStorageMetadata?
    @State private var daemonTraceFilter = ""
    @State private var daemonError: String?
    @State private var sharedBundle: SharedBundle?
    @State private var bundleGenerationError: String?
    @State private var isGeneratingBundle = false

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
            .background(Brutal.cream.ignoresSafeArea())
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
                    Button {
                        Task { await generateDiagnosticsBundle() }
                    } label: {
                        if isGeneratingBundle {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isGeneratingBundle)
                }
            }
            .task {
                loadIOSLogs()
                await loadDaemonLogs()
            }
            .sheet(item: $sharedBundle) { bundle in
                ActivityShareSheet(activityItems: [bundle.url])
            }
            .alert("Couldn't create diagnostics bundle", isPresented: bundleGenerationErrorBinding) {
                Button("OK", role: .cancel) {
                    bundleGenerationError = nil
                }
            } message: {
                Text(bundleGenerationError ?? "Unknown error")
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .iosLogs:
            List {
                metadataSection(title: "iOS Log Storage", metadata: iosLogMetadata)

                ForEach(Array(iosLogs.reversed())) { entry in
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
                    .buttonStyle(BrutalButtonStyle(fill: Brutal.mint, compact: true))
                }

                if let daemonError {
                    Text(daemonError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                List {
                    if let daemonLogMetadata {
                        metadataSection(title: "Daemon Log Storage", metadata: daemonLogMetadata)
                    }

                    ForEach(Array(daemonLogs.reversed())) { entry in
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

    @ViewBuilder
    private func metadataSection(title: String, metadata: LogStorageMetadata) -> some View {
        Section(title) {
            keyValueRow("schemaVersion", "\(metadata.schemaVersion)")
            keyValueRow("service", metadata.service)
            keyValueRow("currentFile", metadata.currentFilePath)
            keyValueRow("currentSize", formatBytes(metadata.currentFileSizeBytes))
            keyValueRow("rotation", "\(formatBytes(metadata.maxFileBytes)) x \(metadata.maxArchivedFiles) archives")
            if let bufferEntryCapacity = metadata.bufferEntryCapacity {
                keyValueRow("bufferCapacity", "\(bufferEntryCapacity)")
            }
            if metadata.archivedFiles.isEmpty {
                keyValueRow("archives", "none")
            } else {
                ForEach(metadata.archivedFiles, id: \.path) { file in
                    keyValueRow(file.name, formatBytes(file.sizeBytes))
                }
            }
        }
    }

    private func loadIOSLogs() {
        iosLogs = Log.buffer.allEntries()
        iosLogMetadata = Log.diagnosticsMetadata()
    }

    private func loadDaemonLogs() async {
        do {
            daemonError = nil
            let traceId = daemonTraceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = try await appState.fetchDaemonLogs(
                count: 200,
                traceId: traceId.isEmpty ? nil : traceId
            )
            daemonLogs = snapshot.entries
            daemonLogMetadata = snapshot.metadata
        } catch {
            daemonError = error.localizedDescription
            daemonLogs = []
            daemonLogMetadata = nil
        }
    }

    private var bundleGenerationErrorBinding: Binding<Bool> {
        Binding(
            get: { bundleGenerationError != nil },
            set: { newValue in
                if !newValue {
                    bundleGenerationError = nil
                }
            }
        )
    }

    private func generateDiagnosticsBundle() async {
        isGeneratingBundle = true
        bundleGenerationError = nil
        loadIOSLogs()
        await loadDaemonLogs()

        let traceId = daemonTraceFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let url = try await appState.createDiagnosticsBundle(
                iosLogs: iosLogs,
                iosLogMetadata: iosLogMetadata,
                daemonLogs: daemonLogs,
                daemonLogMetadata: daemonLogMetadata,
                daemonTraceFilter: traceId.isEmpty ? nil : traceId
            )
            sharedBundle = SharedBundle(url: url)
        } catch {
            bundleGenerationError = error.localizedDescription
        }

        isGeneratingBundle = false
    }

    private func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
