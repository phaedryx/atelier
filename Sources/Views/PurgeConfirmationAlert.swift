// ABOUTME: The one alert body for Remove/Purge confirmations, driven by Workstream.PurgeConfirmation.
// ABOUTME: Views attach it and supply only what happens after the purge.

import SwiftUI

private struct PurgeConfirmationAlert: ViewModifier {
    @ObservedObject var confirmation: Workstream.PurgeConfirmation
    let archiving: Workstream.PurgeConfirmation.ArchiveContext?
    let onPurge: (Workstream.PurgeConfirmation.Completion) -> Void

    func body(content: Content) -> some View {
        content.alert(
            confirmation.title,
            isPresented: $confirmation.isPresented
        ) {
            Button("Cancel", role: .cancel) { confirmation.cancel() }
            Button(confirmation.confirmButtonTitle, role: .destructive) {
                confirmation.perform(archiving: archiving, then: onPurge)
            }
        } message: {
            Text(confirmation.message)
        }
    }
}

extension View {
    /// Renders `confirmation`'s pending purge, whatever it is aimed at.
    ///
    /// The title, the message, the "Purge Anyway" rule and the target's own
    /// lifetime belong to `Workstream.PurgeConfirmation`; a view supplies the
    /// dependencies `Archiver.purge` needs and what to do afterwards, which is
    /// the only thing the three call sites ever genuinely disagreed about — the
    /// sidebar re-selects a sibling, `ContentView` falls back to the project,
    /// the overview refreshes its worktree list.
    ///
    /// `archiving` is nil for a caller that can only hold an orphan target.
    /// `Text(confirmation.message)` and the two button titles take `String`s
    /// that `NSLocalizedString` has already resolved — passing a key here would
    /// look it up twice.
    func purgeConfirmationAlert(
        _ confirmation: Workstream.PurgeConfirmation,
        archiving: Workstream.PurgeConfirmation.ArchiveContext? = nil,
        onPurge: @escaping (Workstream.PurgeConfirmation.Completion) -> Void
    ) -> some View {
        modifier(PurgeConfirmationAlert(confirmation: confirmation, archiving: archiving, onPurge: onPurge))
    }
}
