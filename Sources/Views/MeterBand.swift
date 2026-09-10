// ABOUTME: The sidebar's shared five-band meter color scale, used by the plan
// ABOUTME: usage bars and the workstream context bar so every bar reads alike.

import SwiftUI

/// One color scale for every bar in the sidebar. `UsageMeterView`'s three plan
/// windows and `ContextMeter`'s context window are different quantities, but a
/// user reads them as one stack of bars, so a given color has to mean the same
/// share of "full" in all of them.
enum MeterBand {
    /// Which fifth of the window the usage falls in: 0 = 0–19%, 4 = 80–100%.
    static func band(percentUsed: Int) -> Int {
        min(max(percentUsed, 0) / 20, 4)
    }

    /// Blue → green → yellow → orange → red across the five bands.
    static func color(_ band: Int) -> Color {
        [.blue, .green, .yellow, .orange, .red][min(max(band, 0), 4)]
    }
}
