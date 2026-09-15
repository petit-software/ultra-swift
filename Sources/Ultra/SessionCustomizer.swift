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
    /// The project's agents — what "New Agent Pane" offers. Bound for the same reason the
    /// look is: the row owns the value and writes it to `.ultra/agents.json` on every
    /// change, so there is nothing to confirm and nothing to lose to a closed popover.
    @Binding var agents: [AgentDefinition]
    /// What an empty field falls back to — the project folder's own name. A session with a
    /// blank title is a row you cannot tell from any other blank row.
    let defaultName: String
    let reset: () -> Void

    /// The field takes focus when the popover opens, so ⌃⌘I is "rename this session" in one
    /// keystroke rather than a keystroke and a click.
    @FocusState private var isNameFocused: Bool

    /// Reset offers to undo all four, so it lights up when any one of them has moved.
    private var isCustomized: Bool {
        !appearance.isDefault || name != defaultName || agents != AgentDefinition.builtIns
    }

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

            section("Agents") { agentList }

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

    /// One row per agent: a name, the command line that runs it, and a way to drop it. Two
    /// fields stacked rather than side by side, because the popover is the width of the
    /// symbol grid and a command line needs the whole of it.
    ///
    /// Edits land in the binding keystroke by keystroke and are cleaned on the way out
    /// (`normalize`): a row half-typed when the popover closes is dropped rather than
    /// written as a menu item with no command.
    private var agentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Rows are identified by POSITION, not by `AgentDefinition.id`. That id is the
            // name — right for a menu, wrong for a field editing the name, where every
            // keystroke would give the row a new identity and take the caret with it.
            ForEach(agents.indices, id: \.self) { index in
                let name = index < agents.count ? agents[index].name : ""
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        TextField("Name", text: field(\.name, at: index))
                        Button {
                            if index < agents.count { agents.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(name)")
                        .accessibilityLabel("Remove \(name)")
                    }
                    TextField("Command", text: field(\.command, at: index))
                        .font(.body.monospaced())
                }
                .textFieldStyle(.roundedBorder)
            }
            // Blank, under a name no other row has: the menus that list agents identify
            // them by name, and two rows called the same thing would be one item there.
            Button {
                var number = agents.count + 1
                while agents.contains(where: { $0.name == "Agent \(number)" }) { number += 1 }
                agents.append(AgentDefinition(name: "Agent \(number)", command: ""))
            } label: {
                Label("Add Agent", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Token.Colour.accent)
        }
    }

    /// One field of one row, by position — and guarded, because a row's view outlives its
    /// element by a frame when the row is removed, and `$agents[index]` in that frame is an
    /// out-of-range trap rather than an empty field.
    private func field(_ keyPath: WritableKeyPath<AgentDefinition, String>,
                       at index: Int) -> Binding<String> {
        Binding(
            get: { index < agents.count ? agents[index][keyPath: keyPath] : "" },
            set: { if index < agents.count { agents[index][keyPath: keyPath] = $0 } })
    }

    /// A name of nothing but spaces is a blank row. Fall back to the folder's own name,
    /// which is what the session was called before anyone renamed it.
    ///
    /// The agent list is cleaned the same way: a row with no command, or no name, cannot be
    /// launched and is dropped rather than saved.
    private func normalize() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? defaultName : trimmed
        let cleaned = ProjectAgents.cleaned(agents)
        if cleaned != agents { agents = cleaned }
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
    @Previewable @State var agents = AgentDefinition.builtIns
    SessionCustomizer(name: $name, appearance: $appearance, agents: $agents,
                      defaultName: "ultra-swift") {
        appearance = .default
        name = "ultra-swift"
        agents = AgentDefinition.builtIns
    }
}
