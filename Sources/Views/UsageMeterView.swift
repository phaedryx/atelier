// ABOUTME: Sidebar plan-usage meter: three labeled bars (5h session, weekly all-models,
// ABOUTME: weekly model-specific) fed by Usage.Store. Click forces a refresh.

import SwiftUI

/// Renders nothing until the store has a report, so the sidebar stays clean when
/// `claude` isn't installed or `/usage` has nothing to say.
struct UsageMeterView: View {
    @EnvironmentObject private var usageStore: Usage.Store

    /// Which fifth of the plan window the usage falls in: 0 = 0–19%, 4 = 80–100%.
    static func band(percentUsed: Int) -> Int {
        min(max(percentUsed, 0) / 20, 4)
    }

    /// Blue → green → yellow → orange → red across the five bands.
    static func bandColor(_ band: Int) -> Color {
        [.blue, .green, .yellow, .orange, .red][min(max(band, 0), 4)]
    }

    var body: some View {
        if let report = usageStore.report {
            VStack(spacing: 3) {
                row(
                    label: NSLocalizedString("5h", comment: "Usage meter label: 5-hour session window"),
                    window: report.session,
                    help: NSLocalizedString("Current session", comment: "Usage meter tooltip: 5-hour session window")
                )
                row(
                    label: NSLocalizedString("wk", comment: "Usage meter label: weekly all-models window"),
                    window: report.week,
                    help: NSLocalizedString("Current week (all models)", comment: "Usage meter tooltip: weekly all-models window")
                )
                row(
                    label: NSLocalizedString("fb", comment: "Usage meter label: weekly model-specific window"),
                    window: report.modelWeek,
                    help: modelWeekHelp(report.modelName)
                )
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await usageStore.refresh(force: true) }
            }
        }
    }

    @ViewBuilder
    private func row(label: String, window: Usage.Report.Window?, help: String) -> some View {
        if let window {
            let percent = min(max(window.percentUsed, 0), 100)
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(Self.bandColor(Self.band(percentUsed: percent)))
                            .frame(width: max(0, proxy.size.width * Double(percent) / 100))
                    }
                }
                .frame(height: 3)
                Text("\(percent)%")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            .help(helpText(help, resetText: window.resetText))
        }
    }

    private func modelWeekHelp(_ modelName: String?) -> String {
        String(
            format: NSLocalizedString(
                "Current week (%@)",
                comment: "Usage meter tooltip: weekly model-specific window; placeholder is the model name"
            ),
            modelName ?? NSLocalizedString("model", comment: "Fallback model name in the usage meter tooltip")
        )
    }

    private func helpText(_ name: String, resetText: String?) -> String {
        guard let resetText else { return name }
        return String(
            format: NSLocalizedString(
                "%1$@ — resets %2$@",
                comment: "Usage meter tooltip: window name and reset time"
            ),
            name,
            resetText
        )
    }
}
