// ABOUTME: Onboarding screen shown when no project is selected.
// ABOUTME: Displays tool prerequisites, getting started steps, and key concepts.

import SwiftUI

struct OnboardingView: View {
    let toolStatus: ToolStatus
    let isDetecting: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App header
                VStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text(AppConstants.appName)
                        .font(.system(size: 28, weight: .bold))
                    Text("AI-powered workspaces for your codebase.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Version \(AppConstants.displayVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 24)

                // Prerequisites
                VStack(spacing: 4) {
                    HStack {
                        Text("Prerequisites")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if isDetecting {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }

                    Form {
                        PrerequisiteRow(
                            name: "claude",
                            status: toolStatus.claude,
                            version: toolStatus.claudeVersion,
                            installURL: URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")
                        )
                        PrerequisiteRow(
                            name: "gh",
                            status: toolStatus.gh,
                            version: toolStatus.ghVersion,
                            detail: toolStatus.ghAuthDetail,
                            isAuthenticated: toolStatus.ghAuthenticated
                        )
                        PrerequisiteRow(
                            name: "git",
                            status: toolStatus.git,
                            version: toolStatus.gitVersion
                        )
                        // Required, and listed above tmux for that reason: it
                        // runs every phase a project declares —
                        // prepare, execute and dispose — so a machine
                        // without it has nothing Atelier can do for a project.
                        // It is also the row where the install link earns its
                        // place, since process-compose is not in homebrew-core
                        // and the three directories `resolveBinary` searches
                        // miss every shim-based install.
                        //
                        // `status` comes from `ToolStatus`, which resolves this
                        // one through `ProcessCompose.Settings.resolveBinary()`
                        // rather than the generic binary search — so this row
                        // and the Execution tab's Start button cannot disagree
                        // about whether there is a binary.
                        PrerequisiteRow(
                            name: "process-compose",
                            status: toolStatus.processCompose,
                            version: toolStatus.processComposeVersion,
                            installURL: URL(string: "https://f1bonacc1.github.io/process-compose/installation/")
                        )
                        PrerequisiteRow(
                            name: "tmux",
                            status: toolStatus.tmux,
                            version: toolStatus.tmuxVersion,
                            optional: true
                        )
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                }

                // Getting started
                VStack(spacing: 4) {
                    HStack {
                        Text("Getting Started")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }

                    Form {
                        HStack(spacing: 8) {
                            Text("Add a project")
                            Spacer()
                            shortcutBadge(symbols: ["command", "shift"], text: "N")
                        }
                        HStack(spacing: 8) {
                            Text("Or drag a directory to the sidebar")
                            Spacer()
                            Image(systemName: "sidebar.left")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                }

                // Key concepts
                VStack(spacing: 4) {
                    HStack {
                        Text("Key Concepts")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }

                    Form {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Workstream")
                                .font(.system(.body, weight: .medium))
                            Text("An isolated workspace with its own git branch, terminal, and AI agent.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                shortcutBadge(symbols: ["command"], text: "N")
                                Text("to create one inside a project.")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                }
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .mask(
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
            }
        )
        .background(alignment: .bottom) {
            EaselRowView()
                .padding(.horizontal, 40)
                .padding(.bottom, 10)
        }
    }

    private func shortcutBadge(symbols: [String], text: String) -> some View {
        HStack(spacing: 2) {
            ForEach(symbols, id: \.self) { symbol in
                Text(Image(systemName: symbol))
            }
            Text(text)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
}

/// Internal, not private, so the flag-versus-string decision below can be
/// pinned by a test — the same reason `ToolRow` is.
struct PrerequisiteRow: View {
    let name: String
    let status: BinaryStatus
    var version: String?
    /// Display-only, and free to be reworded — `isAuthenticated` is the flag
    /// this row branches on. See `ToolStatus.ghAuthDetail`.
    var detail: String?
    var isAuthenticated: Bool = false
    var optional: Bool = false
    var installURL: URL?

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)

            Text(name)
                .font(.system(.body, design: .monospaced))

            if let version {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if optional, !status.isInstalled {
                Text("Optional")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if status.isInstalled {
                if let detail {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(ToolRow.authenticationDotColor(isAuthenticated: isAuthenticated))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(isAuthenticated ? "Authenticated" : "Not authenticated")
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !isAuthenticated {
                            Text("Run: gh auth login")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else if let installURL, !optional {
                Link("Install...", destination: installURL)
                    .font(.caption)
            } else if !optional {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if status.isInstalled {
            return "checkmark.circle.fill"
        }
        if optional {
            return "minus.circle"
        }
        return "xmark.circle"
    }

    private var statusColor: Color {
        if status.isInstalled {
            return .green
        }
        if optional {
            return .secondary
        }
        return .orange
    }
}
