import SwiftUI

struct SessionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.sessions) { session in
                    HStack {
                        Text(session.sessionId)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if session.sessionId == appState.currentSessionId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
