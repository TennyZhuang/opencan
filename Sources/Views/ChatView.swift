import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @State private var showSessions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.spacing) {
                            ForEach(appState.messages) { message in
                                MessageRowView(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: appState.messages.count) {
                        if let last = appState.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()
                InputBarView()
            }
            .navigationTitle("OpenCAN")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showSessions.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Disconnect", role: .destructive) {
                        appState.disconnect()
                    }
                }
            }
            .sheet(isPresented: $showSessions) {
                SessionListView()
            }
        }
    }
}