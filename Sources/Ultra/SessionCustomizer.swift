import SwiftUI
import UltraCore
import UltraDesign
import UltraTiles

/// What a session is called, what its sidebar row is drawn with, and which agents it runs.
///
/// A SHEET, in the same dress as the new-project sheet: the same grouped form, the same
/// name-and-icon row, the same capsule buttons under it. It was a popover hung off the
/// sidebar row, which is the right shape for a colour swatch and the wrong one for a list
/// of agents being edited — a popover closes the moment the pointer strays, and a form
/// that vanishes mid-edit is a form you fill in twice. A sheet stays until it is told to go.
///
/// Every edit still writes through immediately — Done only closes. The name and the icon
/// land on the row as they change; the agents land in `.ultra/agents.json` on Save.
struct SessionCustomizer: View {
    /// The name is `LayoutStore.workspaceTitle` reached through a binding, NOT another copy
    /// in `SessionAppearance`. A title is already a first-class field of the workspace
    /// document; storing it twice would give one session two names that can disagree.
    @Binding var name: String
    /// Bound, not passed: the row owns the value and writes it as it changes.
    @Binding var appearance: SessionAppearance
    /// The project's agents — what "New Agent Pane" offers. Bound for the same reason the
    /// look is: the row owns the value and writes it to `.ultra/agents.json` on every
    /// change, so there is nothing to confirm and nothing to lose to a closed sheet.
    @Binding var agents: [AgentDefinition]
    /// What an empty field falls back to — the project folder's own name. A session with a
    /// blank title is a row you cannot tell from any other blank row.
    let defaultName: String
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isChoosingAppearance = false

    /// Which agent row is open for editing, if any, and what its fields hold so far.
    @State private var editingIndex: Int?
    @State private var draftName = ""
    @State private var draftCommand = ""
    @FocusState private var isAgentNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Customize Session")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)

            Form {
                // The name and the row's mark on ONE line, as in the new-project sheet: they
                // are the same question asked twice — what is this called, and what does it
                // look like. The prompt carries the fallback, so an emptied field is not
                // empty, it is showing what the row will say.
                LabeledContent("Name") {
                    HStack(spacing: 8) {
                        TextField("", text: $name, prompt: Text(defaultName))
                            .labelsHidden()
                            // ↩ is "done" here rather than "apply": the name is already
                            // applied, keystroke by keystroke. What it does is normalise and
                            // get out of the way, which is what a user pressing Return expects.
                            .onSubmit { normalize() }
                        appearanceButton
                    }
                }

                Section {
                    agentRows
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Each agent here becomes a shortcut in the pane types, so a pane can be opened running it straight away.")
                }
            }
            .formStyle(.grouped)

            HStack {
                // Always live, and PLAIN — a word in the accent, no bezel. It was a bordered
                // capsule, and in dark appearance a bordered capsule's plate is a mid grey
                // that reads as a disabled control whenever the sheet is key; the same
                // button looked fine only while the window was inactive and the plate went
                // translucent. A secondary action beside the one filled button does not
                // need a plate of its own to be found.
                Button("Reset to Default", action: reset)
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.accent)
                    .controlSize(.large)
                Spacer()
                // Escape closes it, the way Escape leaves the new-project sheet. Return is
                // left to the fields: the name normalises on it and an open agent editor
                // saves on it, and a default button would fire on top of both.
                Button {
                    normalize()
                    dismiss()
                } label: {
                    Text("Done").foregroundStyle(Token.Colour.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Token.Colour.accent)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Nothing is focused when the sheet opens. The name field used to take focus, so
        // ⌃⌘I was "rename" in one keystroke — but a field focused by SwiftUI selects all of
        // its text, and the sheet opened with the session's name lit up as if it were about
        // to be replaced. Tab reaches the field; typing is one keystroke away, not zero.
        // Closing by any route is as much a commit as pressing Return, so an emptied field
        // must not be able to leave a nameless row behind.
        .onDisappear { normalize() }
    }

    /// The colour and the mark as one control, the icon being the preview — the same
    /// control the new-project sheet has in the same place, opening the same picker.
    private var appearanceButton: some View {
        Button { isChoosingAppearance = true } label: {
            SessionIconPreview(appearance: appearance)
                .frame(width: 24, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Choose the colour and symbol this session's sidebar row wears")
        .popover(isPresented: $isChoosingAppearance, arrowEdge: .bottom) {
            SessionAppearancePicker(appearance: $appearance)
                .padding(SessionAppearancePicker.popoverPadding)
                .frame(width: SessionAppearancePicker.width)
        }
    }

    // MARK: - Agents

    /// The agents as rows of the form — a name over its command, one row each — with a row
    /// opened for editing in place when it is asked for. Edits are staged in `draftName` /
    /// `draftCommand` and written on Save, so a slip is undone with Escape rather than
    /// already in `.ultra/agents.json`. Save waits for both halves: an agent with no command
    /// is a menu item that does nothing, which is what `ProjectAgents.cleaned` would drop
    /// on the way out — better not to offer it.
    @ViewBuilder
    private var agentRows: some View {
        // Rows are identified by POSITION, not by `AgentDefinition.id`. That id is the
        // name — right for a menu, wrong for a list being edited, where saving a rename
        // would give the row a new identity and take the focus with it.
        ForEach(agents.indices, id: \.self) { index in
            if editingIndex == index {
                agentEditor(at: index)
            } else if index < agents.count {
                AgentRow(agent: agents[index],
                         edit: { beginEditing(index) },
                         remove: { removeAgent(at: index) })
            }
        }
        // Under the list, where every source list puts "add". Blank, and opened for
        // editing at once: an agent with no command is not worth a row until it has one.
        Button {
            agents.append(AgentDefinition(name: "", command: ""))
            beginEditing(agents.count - 1)
        } label: {
            Label("Add Agent", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.accent)
        .disabled(editingIndex != nil)
    }

    /// The row being edited, on ONE line: the name, the command, and the two ways out. No
    /// labels — the placeholders say what each field is, and the row it replaces had none
    /// either. The check is filled and in the accent, so the one thing that commits is the
    /// one thing that stands out; the cross is the same weight in the label colour.
    private func agentEditor(at index: Int) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $draftName, prompt: Text("Name"))
                .labelsHidden()
                .font(Token.Type_.body)
                .frame(width: 120)
                .focused($isAgentNameFocused)
                .onSubmit(commitEditing)
                .onExitCommand(perform: cancelEditing)
            TextField("", text: $draftCommand, prompt: Text("Command"))
                .labelsHidden()
                .font(Token.Type_.mono)
                .onSubmit(commitEditing)
                .onExitCommand(perform: cancelEditing)
            Button(action: cancelEditing) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Token.Colour.label)
            }
            .help("Cancel")
            .accessibilityLabel("Cancel")
            Button(action: commitEditing) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(canSaveDraft ? Token.Colour.accent : Token.Colour.tertiaryLabel)
            }
            .disabled(!canSaveDraft)
            .help("Save")
            .accessibilityLabel("Save")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16))
        .padding(.vertical, 2)
        .task { isAgentNameFocused = true }
    }

    private var canSaveDraft: Bool {
        !draftName.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func beginEditing(_ index: Int) {
        guard index < agents.count else { return }
        draftName = agents[index].name
        draftCommand = agents[index].command
        editingIndex = index
    }

    private func commitEditing() {
        guard let index = editingIndex, index < agents.count, canSaveDraft else { return }
        agents[index].name = draftName.trimmingCharacters(in: .whitespaces)
        agents[index].command = draftCommand.trimmingCharacters(in: .whitespaces)
        editingIndex = nil
    }

    /// Escape, Cancel, or the sheet closing under an open editor. A row that was blank
    /// when editing began — one just added — has nothing to go back to, so it goes.
    private func cancelEditing() {
        if let index = editingIndex, index < agents.count,
           agents[index].name.isEmpty, agents[index].command.isEmpty {
            agents.remove(at: index)
        }
        editingIndex = nil
    }

    private func removeAgent(at index: Int) {
        guard index < agents.count else { return }
        agents.remove(at: index)
        editingIndex = nil
    }

    /// A name of nothing but spaces is a blank row. Fall back to the folder's own name,
    /// which is what the session was called before anyone renamed it.
    ///
    /// The agent list is cleaned the same way: a row with no command, or no name, cannot be
    /// launched and is dropped rather than saved.
    private func normalize() {
        if editingIndex != nil { cancelEditing() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmed.isEmpty ? defaultName : trimmed
        let cleaned = ProjectAgents.cleaned(agents)
        if cleaned != agents { agents = cleaned }
    }
}

/// One agent, read: its name over the command that runs it, and on hover the two things
/// that can be done to it — floating over the row on the same glass pill a task's controls
/// use, so the row is the same shape hovered or not. Both are buttons, so Tab reaches them.
private struct AgentRow: View {
    let agent: AgentDefinition
    let edit: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    // Set explicitly, to the same 13pt the command's mono token is: left to
                    // the form, the name took whatever size the row handed it.
                    .font(Token.Type_.body)
                    .foregroundStyle(Token.Colour.label)
                    .lineLimit(1)
                // The same size as the name above it, fixed pitch: a command is read, not
                // glanced at, and small print under a name made every row a title with
                // a caption.
                Text(agent.command)
                    .font(Token.Type_.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .tileHoverControls(isHovering) {
            HStack(spacing: 10) {
                Button(action: edit) { Image(systemName: "pencil") }
                    .help("Edit \(agent.name)")
                    .accessibilityLabel("Edit \(agent.name)")
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .help("Remove \(agent.name)")
                    .accessibilityLabel("Remove \(agent.name)")
            }
        }
        .onHover { isHovering = $0 }
        // Double-click to edit, the way a task is edited in the Todo pane. The pencil is
        // the discoverable route; this is the fast one.
        .onTapGesture(count: 2, perform: edit)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Customize", traits: .fixedLayout(width: 500, height: 520)) {
    @Previewable @State var name = "ultra-swift"
    @Previewable @State var appearance = SessionAppearance(symbol: "flame.fill", tint: "orange")
    @Previewable @State var agents = AgentDefinition.known
    SessionCustomizer(name: $name, appearance: $appearance, agents: $agents,
                      defaultName: "ultra-swift") {
        name = "ultra-swift"
        appearance = .default
        agents = AgentDefinition.defaults
    }
}
