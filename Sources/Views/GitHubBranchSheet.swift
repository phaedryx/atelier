// ABOUTME: Sheet asking for the origin branch a new workstream should check out.
// ABOUTME: Sibling of the sidebar's Shortcut sheet; the field takes a branch name only.

import SwiftUI

/// Collects the branch for "New workstream from GitHub".
///
/// Deliberately shaped like the sidebar's Shortcut sheet — same header, project block, single
/// field, error line, and a Create that stays disabled while the branch is being looked up.
/// The lookup happens before anything is created, so `isChecking` is a real wait the user is
/// watching rather than a spinner over work already underway.
struct GitHubBranchSheet: View {
    @Binding var branchInput: String
    @Binding var error: String
    /// Origin is being asked whether it has the branch.
    let isChecking: Bool
    let projectName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("New Workstream from GitHub")
                    .font(.headline)
            }

            Divider()
                .opacity(0.35)

            VStack(alignment: .leading, spacing: 4) {
                Text("Project")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Branch")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(Text("The branch must already exist on origin. The workstream takes its name."))
                        .accessibilityLabel(Text("More info"))
                }
                TextField("", text: $branchInput, prompt: Text(verbatim: "feat-thing")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFocused)
                    .disabled(isChecking)
                    .onSubmit { onCreate() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.small)
                }
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isChecking || branchInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { isFocused = true }
    }
}
