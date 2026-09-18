// ABOUTME: The keyboard-driven result list under a filter field, shared by the
// ABOUTME: ⌘⇧P command palette and the editor's ⌘P file finder.

import SwiftUI

/// The id selected after moving `delta` rows from `current`.
///
/// Selection is an **id**, never an index: both call sites rebuild their result
/// array on every keystroke, and an index into an array that no longer exists is
/// how a lazy container ends up rendering one row's content under another row's
/// identity. Moving past either end clamps rather than wrapping — an arrow held
/// down should settle at the end of the list, not cycle through it forever.
///
/// With nothing selected, a downward move takes the first row and an upward move
/// the last, which is what "arrow into the list from the field" means in each
/// direction. An id that is no longer in `ids` is treated the same way, because
/// the row it named is gone.
func neighbouringSelection<ID: Hashable>(from current: ID?, in ids: [ID], delta: Int) -> ID? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
        return delta > 0 ? ids.first : ids.last
    }
    return ids[min(max(index + delta, 0), ids.count - 1)]
}

/// A `List` of filter results driven from somewhere else's keyboard.
///
/// Focus stays in the filter field above — that is what a palette *is* — so this
/// list never takes the keyboard itself (`.focusable(false)`); its owner moves
/// `selection` with `neighbouringSelection` and this scrolls to follow. What
/// `List` buys over the hand-rolled `ScrollView`/`LazyVStack` it replaces is one
/// identity system instead of two, its own selection colour instead of a painted
/// background, and rows that are real `Button`s and so reachable by VoiceOver.
///
/// **It never draws an empty state.** Both call sites distinguish more than one
/// kind of empty — the finder has three (scanning, no match, nothing typed yet) —
/// so they keep their own `if items.isEmpty` and only ever hand this a non-empty
/// array.
///
/// **Activation is the owner's decision, not this view's.** `onActivate` fires
/// for every row, including one the owner will refuse: the palette lists a
/// disabled command deliberately and answers a press on it by staying up with
/// the reason on screen, so the refusal has to live in one place at the owner
/// rather than as a `.disabled()` here that would also take the row's
/// selectability with it.
struct FilterResultList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @Binding var selection: ID?
    /// Height of one row, and the unit the list's own height is counted in.
    let rowHeight: CGFloat
    /// The tallest the list may grow before it scrolls.
    let maxHeight: CGFloat
    let onActivate: (Item) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(items, id: id) { item in
                    Button {
                        // Set the selection first: a `Button` filling a `List`
                        // row swallows the click the list would have selected
                        // with, so without this a click on a row the owner
                        // refuses leaves the highlight where it was.
                        selection = item[keyPath: id]
                        onActivate(item)
                    } label: {
                        row(item, item[keyPath: id] == selection)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .tag(item[keyPath: id])
                }
            }
            .listStyle(.plain)
            // Same problem, and the same answer, as `ChangesFileTreeSidebar`:
            // `.plain` plus a hidden scroll background is what lets the panel's
            // material show through instead of the list painting over it.
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, rowHeight)
            // `List` insets its content vertically by default, which would put
            // the last row past the height computed below and leave a list that
            // scrolls despite every row fitting.
            .contentMargins(.vertical, 0, for: .scrollContent)
            // `List` has no ideal height, so `maxHeight:` alone would give a
            // palette 320pt tall over a single result. Pinning the row height
            // above makes this arithmetic exact rather than estimated.
            .frame(height: min(CGFloat(items.count) * rowHeight, maxHeight))
            // The field above holds the keyboard and must keep it. This stops
            // the list becoming a second candidate for it; it says nothing
            // about the palette's own focus dance, which is untouched.
            .focusable(false)
            .onChange(of: selection) { _, newValue in
                guard let newValue else { return }
                withAnimation(nil) { proxy.scrollTo(newValue) }
            }
        }
    }
}
