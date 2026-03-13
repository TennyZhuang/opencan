import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var sourceRepository: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenCANSourceRepository") as? String
            ?? "https://github.com/TennyZhuang/opencan"
    }

    private var sourceRevision: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenCANSourceRevision") as? String ?? "Unknown"
    }

    private var sourceCommitURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "OpenCANSourceCommitURL") as? String
    }

    private var sourceRepositoryURL: URL? {
        URL(string: sourceRepository)
    }

    private var sourceCommitLinkURL: URL? {
        guard let sourceCommitURL else { return nil }
        return URL(string: sourceCommitURL)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("OpenCAN") {
                    Text("Copyright (C) 2026 TennyZhuang")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build", value: buildNumber)
                    LabeledContent("Revision", value: sourceRevision)
                    if let sourceRepositoryURL {
                        Link("Source Repository", destination: sourceRepositoryURL)
                    }
                    if let sourceCommitLinkURL {
                        Link("Source Revision", destination: sourceCommitLinkURL)
                    }
                }

                Section("License") {
                    Text("OpenCAN is free software licensed under the GNU Affero General Public License v3.0 or later.")
                    Text("This program is provided without warranty, and licensees may convey it under the terms of the AGPL. See the bundled license text and repository source for details.")
                    Link("View AGPL v3.0", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.en.html")!)
                }

                Section("Acknowledgements") {
                    Text("The chat timeline UI direction was informed by FlowDown by Lakr233.")
                    Text("OpenCAN directly depends on ListViewKit, MarkdownView, and Citadel. See THIRD_PARTY_NOTICES.md in the repository for license details.")
                    Link("FlowDown", destination: URL(string: "https://github.com/Lakr233/FlowDown")!)
                    Link("Third-Party Notices", destination: URL(string: "https://github.com/TennyZhuang/opencan/blob/master/THIRD_PARTY_NOTICES.md")!)
                    Link("Open Source Release Notes", destination: URL(string: "https://github.com/TennyZhuang/opencan/blob/master/docs/open-source-release.md")!)
                }

                Section("Release Notes") {
                    Text("Before public release, verify that distributed app and daemon builds map to the exact corresponding source revision and that no proprietary FlowDown brand assets are reused.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brutal.cream.ignoresSafeArea())
            .navigationTitle("About & Licenses")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
