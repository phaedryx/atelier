// ABOUTME: Horizontal context-window meter (bar + percentage) used on the
// ABOUTME: workstream row.

import SwiftUI

/// Context-window usage indicator. Two pressures act on a context window, and
/// each gets its own channel rather than being folded into one color:
///
/// - *Capacity* colors the **bar**: share of the (inferred) model window,
///   banded by `MeterBand` — blue, green, yellow, orange, red in twenty-point
///   steps, the same scale the plan usage bars above it use, so a given color
///   means the same share of "full" everywhere in the sidebar.
/// - *Quality* colors the **token count**: past
///   `ContextLimits.qualityCautionThreshold` (~200k) "212k" turns orange, past
///   `qualityCriticalThreshold` (300k) red, because response quality decays in
///   absolute terms even when a large window still has room. Below caution the
///   count stays secondary — color appears only when it has something to say.
///
/// Folding quality into the bar is what this replaced, and it made the bar lie
/// about the one thing a bar is read for: 250k of a 1M window is a quarter
/// full, and painting that stripe orange said it was three-quarters full. The
/// number is the right home for a threshold on the number.
///
/// Renders as a flexible track filling the available width with a
/// "12.3k · 6%" label trailing.
struct ContextMeter: View {
    let usage: Workstream.AgentStateTracker.ContextUsage

    /// Whether the agent is actively spending context. Dims the **bar** only:
    /// an idle row is exactly when the sidebar is scanned to decide what to
    /// pick up next, so the token count — the channel that says "don't add
    /// more to this one" — stays at full strength.
    var isActive: Bool = true

    /// Resting opacity for the bar. Light, because the bar draws from
    /// `MeterBand`, the same palette as the plan usage bars right above it, and
    /// a heavy dim turns a shared color into a different, muddier one.
    private static let idleBarOpacity: Double = 0.8

    private var fraction: Double {
        min(max(usage.fraction, 0), 1)
    }

    // MARK: Bands

    /// `MeterBand` band for the absolute token count, or nil while the count is
    /// still healthy. Internal + pure for unit testing.
    ///
    /// Quality thresholds are absolute, not relative to the window: 200k tokens
    /// is 200k tokens whether it fills a small window or takes a fifth of a
    /// large one, and response quality decays long before a 1M window is
    /// actually full. Bands 3 and 4 keep it on the shared palette — the same
    /// orange and red the bar reaches at 60% and 80% capacity.
    static func qualityBand(usedTokens: Int) -> Int? {
        if usedTokens >= ContextLimits.qualityCriticalThreshold {
            return 4
        }
        if usedTokens >= ContextLimits.qualityCautionThreshold {
            return 3
        }
        return nil
    }

    /// Percent of the window, computed once and used for both the bar's color
    /// and the label, so a bar reading "20%" cannot be colored as 19%.
    private var percentUsed: Int {
        Int(fraction * 100)
    }

    private var fillColor: Color {
        MeterBand.color(MeterBand.band(percentUsed: percentUsed))
    }

    /// Secondary while healthy, so the count only takes on color once the
    /// quality thresholds have something to report.
    private var tokenStyle: AnyShapeStyle {
        guard let band = Self.qualityBand(usedTokens: usage.usedTokens) else {
            return AnyShapeStyle(.secondary)
        }
        return AnyShapeStyle(MeterBand.color(band))
    }

    // MARK: Labels

    private var percentLabel: String {
        "\(percentUsed)%"
    }

    /// Compact token count: 999 → "999", 12_340 → "12.3k",
    /// 145_234 → "145k", 1_234_567 → "1.2M".
    static func compactTokenCount(_ tokens: Int) -> String {
        let tokens = max(tokens, 0)
        switch tokens {
        case ..<1000: return "\(tokens)"
        case ..<100_000: return String(format: "%.1fk", Double(tokens) / 1000)
        case ..<1_000_000: return "\(tokens / 1000)k"
        default: return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }

    /// "12.3k · 6%" — the row bar's trailing label, in two runs so the token
    /// count can carry the quality color while the percentage, which the bar
    /// already colors, stays secondary.
    private var barLabel: Text {
        Text(Self.compactTokenCount(usage.usedTokens))
            .foregroundStyle(tokenStyle)
            + Text(verbatim: " · \(percentLabel)")
            .foregroundStyle(.secondary)
    }

    var body: some View {
        HStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(height: 3)
            .opacity(isActive ? 1 : Self.idleBarOpacity)
            .animation(.easeInOut(duration: 0.2), value: isActive)
            barLabel
                .font(.system(size: 8, design: .monospaced))
                .fixedSize()
        }
        .help(barHelpText)
    }

    private var barHelpText: String {
        String(
            format: NSLocalizedString(
                "Context: %1$lld tokens · %2$lld%%",
                comment: "Tooltip for the workstream context bar: exact token count and percent of window"
            ),
            usage.usedTokens,
            percentUsed
        )
    }
}
