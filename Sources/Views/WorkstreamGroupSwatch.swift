// ABOUTME: The colour and menu title a workstream group is shown with.
// ABOUTME: Kept apart from the model so Workstream.Group stays free of SwiftUI.
import AppKit
import SwiftUI

extension Workstream.Group {
    /// The one colour mapping. `color` derives from it so the dot in the row
    /// and the swatch in the menu cannot disagree.
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .cyan: .systemCyan
        case .purple: .systemPurple
        }
    }

    /// What "no group" is drawn with: the spine and the menu's None swatch.
    /// Gray is not a group for that reason, and blue is not one because the
    /// sidebar's selection fill is the accent, so a blue spine vanished on the
    /// selected row.
    static let noneNSColor: NSColor = .systemGray

    static var noneColor: Color {
        Color(nsColor: noneNSColor)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    /// A filled circle for the context menu's Group submenu.
    ///
    /// A bitmap, not `Image(systemName: "circle.fill").foregroundStyle(_:)`:
    /// SwiftUI's `.contextMenu` is bridged to an `NSMenu`, which renders a
    /// symbol image as a template and discards its tint, so every swatch came
    /// out white. A non-template `NSImage` is drawn as-is.
    var swatchImage: NSImage {
        Self.swatchImage(nsColor)
    }

    /// The None item's swatch, so "no group" shows the gray the spine draws.
    static var noneSwatchImage: NSImage {
        swatchImage(noneNSColor)
    }

    private static func swatchImage(_ nsColor: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    var title: LocalizedStringKey {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .cyan: "Cyan"
        case .purple: "Purple"
        }
    }
}
