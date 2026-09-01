import SwiftUI
import UltraCore
import UltraDesign

/// What a session is called, and what its sidebar row is drawn with.
///
/// A popover hung off the row itself rather than a pane in Settings: these are properties of
/// ONE project, and a setting about one thing belongs next to that thing. Settings is for
/// what is true of the whole app.
///
/// Every edit writes through immediately — there is no OK button, because there is nothing
/// to confirm. The row behind the popover is the preview, and it renames as you type.
struct SessionCustomizer: View {
    /// The name is `LayoutStore.workspaceTitle` reached through a binding, NOT another copy
    /// in `SessionAppearance`. A title is already a first-class field of the workspace
    /// document; storing it twice would give one session two names that can disagree.
    @Binding var name: String
    /// Bound, not passed: the row owns the value so it redraws under the popover as the
    /// user tries colours, which is the whole reason to make this a live picker.
    @Binding var appearance: SessionAppearance
    /// What an empty field falls back to — the project folder's own name. A session with a
    /// blank title is a row you cannot tell from any other blank row.
    let defaultName: String
    let reset: () -> Void

    /// The field takes focus when the popover opens, so ⌃⌘I is "rename this session" in one
    /// keystroke rather than a keystroke and a click.
    @FocusState private var isNameFocused: Bool

    /// Reset offers to undo all three, so it lights up when any one of them has moved.
    private var isCustomized: Bool { !appearance.isDefault || name != defaultName }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Name") {
                TextField(defaultName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    // ↩ is "done" here rather than "apply": the name is already applied,
                    // keystroke by keystroke. What it does is normalise and get out of the
                    // way, which is what a user pressing Return expects.
                    .onSubmit { normalize() }
            }

            // The colour and the symbol come from the SHARED picker — the new-project
            // sheet asks the same question before the project exists, and two copies of a
            // swatch grid is how the two end up with different swatches.
            SessionAppearancePicker(appearance: $appearance)

            Divider()

            // Dimmed rather than hidden on an untouched session: an item that appears and
            // disappears is one the user has to hunt for.
            Button("Reset to Default", action: reset)
                .disabled(!isCustomized)
        }
        .padding(14)
        .frame(width: SessionAppearancePicker.width)
        .onAppear { isNameFocused = true }
        // Closing by clicking away is as much a commit as pressing Return, so an emptied
        // field must not be able to leave a nameless row behind.
        .onDisappear { normalize() }
    }

    /// A name of nothing but spaces is a blank row. Fall back to the folder's own name,
    /// which is what the session was called before anyone renamed it.
    private func normalize() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? defaultName : trimmed
    }

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

#Preview("Session customizer") {
    @Previewable @State var appearance = SessionAppearance(symbol: "flame.fill", tint: "orange")
    @Previewable @State var name = "ultra-swift"
    SessionCustomizer(name: $name, appearance: $appearance, defaultName: "ultra-swift") {
        appearance = .default
        name = "ultra-swift"
    }
}
