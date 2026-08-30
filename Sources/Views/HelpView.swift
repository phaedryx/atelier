// ABOUTME: Help view showing app info, version, and keyboard shortcuts.
// ABOUTME: Displayed in the detail pane via the help icon or Cmd+?.

import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App header
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)
                    Text(AppConstants.appName)
                        .font(.system(size: 28, weight: .bold))
                    Text("Version \(AppConstants.displayVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    (Text("Made with ") + Text("\u{2764}\u{FE0F}") + Text(" in Poblenou, Barcelona"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 24)
                .padding(.bottom, -4)

                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Text("Forked by ")
                            .foregroundStyle(.tertiary)
                        Link("Tad Thorley", destination: AppConstants.repositoryURL)
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        HStack(spacing: 0) {
                            Text("based on ")
                                .foregroundStyle(.tertiary)
                            Link("Factory Floor", destination: AppConstants.upstreamURL)
                                .foregroundStyle(.secondary)
                            Text(" by ")
                                .foregroundStyle(.tertiary)
                            Link("David Poblador i Garcia", destination: AppConstants.upstreamAuthorURL)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 0) {
                            Text("and additional work by ")
                                .foregroundStyle(.tertiary)
                            Link("Andrés González", destination: AppConstants.upstreamEnhancerURL)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 11))

                PoblenouSkylineView()
                    .padding(.horizontal, 40)
                    .padding(.vertical, -4)

                HStack(spacing: 16) {
                    Link(destination: AppConstants.documentationURL) {
                        Label("Documentation", systemImage: "book")
                    }
                    Link(destination: AppConstants.sponsorURL) {
                        Label("Sponsor", systemImage: "heart")
                    }
                    Link(destination: URL(string: "https://github.com/phaedryx/atelier/issues/new?template=bug_report.yml")!) {
                        Label("Report a Bug", systemImage: "ladybug")
                    }
                    Link(destination: URL(string: "https://github.com/phaedryx/atelier/issues/new?template=feature_request.yml")!) {
                        Label("Request a Feature", systemImage: "lightbulb")
                    }
                }
                .font(.system(size: 11))

                Text("Shortcuts")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 8)

                Form {
                    Section {
                        ShortcutRow(keys: ",", description: "Settings")
                        ShortcutRow(keys: "/", description: "Help")
                        ShortcutRow(keys: "N", description: "New workstream or project")
                        ShortcutRow(keys: "N", shift: true, description: "New project")
                        ShortcutRow(keys: "C", shift: true, description: "Toggle sidebar")
                        ShortcutRow(keys: "P", shift: true, description: "Command Palette")
                    } header: {
                        ShortcutSectionHeader(title: "Global", description: "Available everywhere")
                    }

                    Section {
                        ShortcutRow(keys: "1", description: "Info")
                        ShortcutRow(keys: "2", description: "Coding Agent")
                        ShortcutRow(keys: "3-9", description: "Switch tab")
                        ShortcutRow(keys: "[", shift: true, description: "Previous tab")
                        ShortcutRow(keys: "]", shift: true, description: "Next tab")
                        ShortcutRow(keys: "Return", description: "Focus Coding Agent")
                        ShortcutRow(keys: "P", description: "Find File")
                        ShortcutRow(keys: "S", description: "Save (Editor)")
                        ShortcutRow(keys: "S", shift: true, description: "Save As (Editor)")
                        ShortcutRow(keys: "W", description: "Close tab")
                        ShortcutRow(keys: "R", shift: true, description: "Rename workstream")
                        ShortcutRow(keys: "W", shift: true, description: "Archive workstream")
                        ShortcutRow(keys: "L", description: "Address bar")
                        ShortcutRow(keys: "Return", shift: true, description: "Start/Rerun")
                    } header: {
                        ShortcutSectionHeader(title: "Workstream", description: "When a workstream is active")
                    }

                    Section {
                        ShortcutRow(keys: "[", description: "Previous workstream")
                        ShortcutRow(keys: "]", description: "Next workstream")
                        ShortcutRow(keys: "↑", description: "Previous project")
                        ShortcutRow(keys: "↓", description: "Next project")
                        ShortcutRow(keys: "0", description: "Back to project")
                    } header: {
                        ShortcutSectionHeader(title: "Navigation", description: "Move between workstreams and projects")
                    }

                    Section {
                        ShortcutRow(keys: "B", option: true, description: "Open in external browser")
                        ShortcutRow(keys: "T", option: true, description: "Open in external terminal")
                    } header: {
                        ShortcutSectionHeader(title: "External Apps", description: "Opens the current workstream directory")
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShortcutSectionHeader: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ShortcutRow: View {
    let keys: String
    var ctrl: Bool = false
    var option: Bool = false
    var shift: Bool = false
    var cmd: Bool = true
    let description: String

    var body: some View {
        LabeledContent(description) {
            HStack(spacing: 2) {
                if ctrl { Image(systemName: "control") }
                if cmd { Image(systemName: "command") }
                if option { Image(systemName: "option") }
                if shift { Image(systemName: "shift") }
                Text(keys)
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}
