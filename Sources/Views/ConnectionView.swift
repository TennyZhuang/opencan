import SwiftUI

struct ConnectionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "terminal")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)

                Text("OpenCAN")
                    .font(.largeTitle.bold())

                Text("ACP Client over SSH")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    configRow("Server", value: appState.serverConfig.name)
                    configRow("Host", value: appState.serverConfig.host)
                    if let jump = appState.serverConfig.jumpHost {
                        configRow("Jump", value: jump)
                    }
                    configRow("User", value: appState.serverConfig.username)
                    configRow("Command", value: appState.serverConfig.command)
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let error = appState.connectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button(action: { appState.connect() }) {
                    Group {
                        if appState.connectionStatus == .connecting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Connect")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(appState.connectionStatus == .connecting)
            }
            .padding()
            .onAppear {
                // Auto-connect for faster iteration
                if appState.connectionStatus == .disconnected {
                    appState.connect()
                }
            }
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}