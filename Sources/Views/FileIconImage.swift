// ABOUTME: Draws a FileTypeIcon for the file tree and the file finder.
// ABOUTME: Picks colour on the dark sidebar and a secondary tint on the light one.

import SwiftUI

/// Draws one row's icon: in its own colours on the dark sidebar, tinted to match
/// the surrounding secondary text on the light one.
///
/// vscicons artwork carries saturated brand colour that reads well on a dark
/// background and fights a light one. Template rendering keys off the alpha
/// channel, so tinting keeps the glyph — including knocked-out detail like the
/// letters in the TypeScript tile — rather than flattening it to a block.
struct FileIconImage: View {
    let icon: FileTypeIcon

    @Environment(\.colorScheme) private var colorScheme

    /// The artwork is drawn for a 16px sidebar. Below roughly 14pt the denser
    /// marks — the Docker whale, the Rust gear — lose their detail, so these sit
    /// slightly larger than the 11pt SF Symbols they replaced.
    private static let size: CGFloat = 15

    var body: some View {
        Image(icon.resourceName)
            .renderingMode(colorScheme == .dark ? .original : .template)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.size, height: Self.size)
            .foregroundStyle(.secondary)
    }
}
