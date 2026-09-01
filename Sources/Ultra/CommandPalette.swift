import SwiftUI
import UltraCanvas
import UltraDesign

@MainActor
@Observable
final class UIState {
    var isPaletteShown = false
    /// Whether the SELECTED session's customise popover is open.
    ///
    /// Window state rather than row state, because the popover has two ways in — the row's
    /// context menu and File ▸ Session ▸ Customize Session… — and a flag owned by the row
    /// could only be reached by the first. A context menu is a *view* of the command
    /// registry, never the only way to do something; see the `keyboard-first` skill.
    var isCustomizingSession = false
    /// Whether the new-project sheet is up.
    ///
    /// Window state rather than sidebar state, for the same reason as the flag above: there
    /// are two ways in — the sidebar's `+` and File ▸ New Project… — and a flag owned by the
    /// bar could only be reached by the first. The menu item is not a convenience; it is the
    /// keyboard path, and a command reachable only from a control is the anti-pattern the
    /// `keyboard-first` skill names outright.
    var isCreatingProject = false
}

/// The universal fallback: every registered command, fuzzy-searchable, with its binding
/// shown beside it so the palette teaches shortcuts rather than replacing them.
struct CommandPalette: View {
    let store: LayoutStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var queryFocused: Bool

    private var matches: [AppCommand] {
        guard !query.isEmpty else { return PaneCommands.all }
        return PaneCommands.all.filter { fuzzyMatch(query, $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(12)
                .focused($queryFocused)
                .onSubmit(runSelected)

            Divider()

            List(matches, selection: $selection) { command in
                HStack {
                    Text(command.title)
                        .foregroundStyle(command.isEnabled(store) ? .primary : .secondary)
                    Spacer()
                    if let binding = command.defaultBinding {
                        Text(binding.display)
                            .font(Token.Type_.monoSmall)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
                .tag(command.id)
                .onTapGesture { run(command) }
            }
            .listStyle(.plain)
        }
        .frame(width: 460, height: 380)
        .onAppear {
            queryFocused = true
            selection = matches.first?.id
        }
        .onChange(of: query) { selection = matches.first?.id }
        // Esc cancels any transient mode.
        .onExitCommand { isPresented = false }
    }

    private func runSelected() {
        guard let match = matches.first(where: { $0.id == selection }) ?? matches.first else { return }
        run(match)
    }

    private func run(_ command: AppCommand) {
        guard command.isEnabled(store) else { NSSound.beep(); return }
        isPresented = false
        command.run(store)
    }
}

/// Subsequence match — "spr" finds "Split Right".
private func fuzzyMatch(_ needle: String, _ haystack: String) -> Bool {
    var remaining = Substring(haystack.lowercased())
    for character in needle.lowercased() {
        guard let index = remaining.firstIndex(of: character) else { return false }
        remaining = remaining[remaining.index(after: index)...]
    }
    return true
}

#Preview("Command palette", traits: .fixedLayout(width: 500, height: 420)) {
    @Previewable @State var shown = true
    CommandPalette(store: .placeholders(.grid2x2), isPresented: $shown)
}
