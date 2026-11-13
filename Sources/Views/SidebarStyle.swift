// ABOUTME: The sidebar's surface colours and the flat, always-emphasised row
// ABOUTME: selection that replaced the system sidebar capsule.

import AppKit
import SwiftUI

/// Colours for the sidebar's surface and its selected row.
///
/// The sidebar is a `.plain` `List` on a tinted surface, with a flat,
/// edge-to-edge selection fill drawn by the rows themselves. Three decisions
/// live here:
///
/// - **The tint is the accent over the window colour**, not a fixed navy. It
///   follows the user's accent, so the selection fill and the surface are
///   always the same hue, in both appearances.
/// - **The selection fill is `selectedContentBackgroundColor`**, the colour
///   AppKit uses for an *emphasised* selection, and it is used whether or not
///   the list has focus. The sidebar almost never has focus — the terminal
///   does — so the system's unfocused grey was what the selected row showed
///   nearly all of the time, and it read as a hover, not a selection.
/// - **Selected rows set one foreground style at their root** and let the
///   hierarchical styles inside (`.primary`, `.secondary`, `.tertiary`,
///   `.quaternary`) derive from it, so every label inside a selected row turns
///   white at the right weight without each one checking `isSelected`. Only
///   leaves that name a concrete `Color` — status dots, group dots, PR glyphs,
///   meter bands — keep their colour on the fill.
enum SidebarStyle {
    /// How much accent is laid over the window colour for the surface tint.
    private static let tintOpacity: Double = 0.12

    /// The sidebar's surface: window colour under a wash of the accent.
    static var surface: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(Color.accentColor.opacity(tintOpacity))
    }

    /// Fill behind the selected row. Emphasised regardless of focus.
    static var selectionFill: Color {
        Color(nsColor: .selectedContentBackgroundColor)
    }

    /// Foreground for everything inside the selected row.
    static var selectedForeground: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }

    /// Row background for `.listRowBackground`: the fill when selected, nothing
    /// otherwise. Clear rather than nil so the row keeps one background view
    /// across the selection change instead of adding and removing one.
    static func rowBackground(isSelected: Bool) -> some View {
        (isSelected ? selectionFill : .clear)
            .background(SelectionHighlightDisabler())
    }
}

/// Turns off the `NSTableView`'s own selection highlight so the rows' flat
/// fill is the only one drawn.
///
/// `List` on macOS is an `NSTableView`, and under either list style it paints
/// its selection *over* `listRowBackground` — the `.sidebar` capsule, or
/// `.plain`'s full-width band that goes grey whenever the list is not the
/// first responder. SwiftUI exposes no modifier for that highlight, so this
/// sits in a row's background, walks up to the table it was placed in, and
/// sets `selectionHighlightStyle` to `.none`. Selection itself is unaffected:
/// clicks, arrow keys and `List(selection:)` all still work; only the drawing
/// stops. It is idempotent, so every row may carry one.
private struct SelectionHighlightDisabler: NSViewRepresentable {
    func makeNSView(context _: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_: ProbeView, context _: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableHighlight()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            disableHighlight()
        }

        override var isOpaque: Bool {
            false
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        private func disableHighlight() {
            var view: NSView? = superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                view = current.superview
            }
        }
    }
}
