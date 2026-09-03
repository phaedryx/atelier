// ABOUTME: Per-agent mini cards shown under an expanded workstream row while
// ABOUTME: subagents are live in that workstream.

import SwiftUI

/// One card per live SUBAGENT run, mirroring the workstream row's design in
/// miniature: type name over a status meta line (dot + word · activity ·
/// elapsed). The main agent is not listed — its status line and context bar
/// live on the workstream row itself. Cards
/// exist exactly while their run is live — Claude Code's stop hooks remove
/// them the moment an agent finishes.
struct WorkstreamAgentRosterView: View {
    let runs: [Workstream.AgentStateTracker.AgentRun]
    /// Called when a roster line is clicked: selects the workstream and
    /// focuses its Coding Agent tab.
    let onSelect: () -> Void

    private static let maxVisibleLines = 3

    private var visibleRuns: [Workstream.AgentStateTracker.AgentRun] {
        Array(runs.prefix(Self.maxVisibleLines))
    }

    private var hiddenCount: Int {
        max(0, runs.count - Self.maxVisibleLines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(visibleRuns) { run in
                RosterCard(run: run)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
            }
            if hiddenCount > 0 {
                Text(String(format: NSLocalizedString("+%d more", comment: "Additional agents beyond the visible roster lines"), hiddenCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .onTapGesture(perform: onSelect)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: Text {
        var text = Text("\(runs.count)")
        for run in runs {
            let cap = run.name.capitalizedFirst
            text = text + Text(", ") + Text(cap)
        }
        return text
    }
}

// MARK: - Single roster card

private struct RosterCard: View {
    let run: Workstream.AgentStateTracker.AgentRun

    private var statusColor: Color {
        switch run.state {
        case .working: .blue
        case .stalled: .yellow
        }
    }

    private var statusWord: LocalizedStringKey {
        switch run.state {
        case .working: "Working"
        case .stalled: "Stalled"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                statusMeta
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .help(displayName)
        .padding(.vertical, 2)
    }

    /// "● Working · Editing Foo.swift · 2m" — same grammar as the workstream
    /// row's status line, driven by this run's own state.
    private var statusMeta: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .padding(.trailing, 4)

            Text(statusWord)
                .foregroundStyle(statusColor)

            if let activity = run.activity {
                metaSeparator
                Text(activity)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            metaSeparator
            ElapsedLabel(startedAt: run.startedAt, fontSize: 9)
        }
        .font(.system(size: 9, design: .monospaced))
        .lineLimit(1)
    }

    private var metaSeparator: some View {
        Text("·")
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 3)
    }

    private var displayName: String {
        run.name.capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Elapsed time

/// Ticking "4m"-style label counting up from a run's start. Shared by roster
/// cards and the workstream row's status line.
struct ElapsedLabel: View {
    let startedAt: Date
    var fontSize: CGFloat = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Text(Self.elapsed(from: startedAt))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .accessibilityHidden(true)
    }

    static func elapsed(from start: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(start))
        let minutes = Int(interval) / 60
        if minutes >= 60 {
            return String(format: "%dh%02d", minutes / 60, minutes % 60)
        }
        if minutes >= 1 {
            return String(format: "%dm", minutes)
        }
        return String(format: "%ds", Int(interval))
    }
}
