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
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: appState.scrollTrigger) {
                        // Small delay so SwiftUI finishes layout before scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("bottom")
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
