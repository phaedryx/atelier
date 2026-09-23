// ABOUTME: The one alert body for Remove confirmations, driven by Workstream.RemoveConfirmation.
// ABOUTME: Views attach it and supply only what happens after the removal.

import SwiftUI

private struct RemoveConfirmationAlert: ViewModifier {
    @ObservedObject var confirmation: Workstream.RemoveConfirmation
    let archiving: Workstream.ArchiveContext
    let selection: Binding<SidebarSelection?>
    let onRemove: (Workstream.RemoveConfirmation.Completion) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Remove Workstream",
            isPresented: $confirmation.isPresented
        ) {
            Button("Cancel", role: .cancel) { confirmation.cancel() }
            Button("Remove", role: .destructive) {
                confirmation.perform(archiving: archiving, selection: selection, then: onRemove)
            }
        } message: {
            Text("Ongoing terminals and Coding Agent sessions will be killed. The worktree and its files will remain on disk.")
        }
    }
}

extension View {
    /// Renders `confirmation`'s pending removal.
    ///
    /// The sibling of `purgeConfirmationAlert`, and it exists for the reason
    /// that one did: this alert and the twenty lines behind it were copied into
    /// `ContentView` and `ProjectSidebar`, and the copies had already drifted —
    /// only the sidebar's moved the selection off the workstream it removed.
    ///
    /// Unlike the purge alert there is nothing to decide about the copy: Remove
    /// destroys nothing, so the title, the message and the button title are
    /// fixed and live here rather than on the model. `archiving` is not
    /// optional, because there is no caller that can raise this alert without
    /// being able to perform it.
    ///
    /// What a view still supplies is its own bookkeeping afterwards — saving the
    /// project list and resyncing the head watcher, or rebuilding the sidebar's
    /// positional indices — which is the only thing the two call sites ever
    /// genuinely disagreed about.
    func removeConfirmationAlert(
        _ confirmation: Workstream.RemoveConfirmation,
        archiving: Workstream.ArchiveContext,
        selection: Binding<SidebarSelection?>,
        onRemove: @escaping (Workstream.RemoveConfirmation.Completion) -> Void
    ) -> some View {
        modifier(
            RemoveConfirmationAlert(
                confirmation: confirmation,
                archiving: archiving,
                selection: selection,
                onRemove: onRemove
            )
        )
    }
}
