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

    /// Nothing until something is typed. An unfiltered list of every command on open is
    /// forty rows to scan before the field you meant to type into; the empty palette is a
    /// field and nothing else, and the list grows under it as the query narrows.
    private var matches: [AppCommand] {
        guard !query.isEmpty else { return [] }
        return PaneCommands.all.filter { fuzzyMatch(query, $0.title) }
    }

    /// The palette's outline. Continuous, and generous: it floats free of every edge now
    /// rather than hanging from the title bar, so it wears a window's radius.
    private var shape: some InsettableShape {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                TextField("Run a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($queryFocused)
                    .onSubmit(runSelected)
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if !query.isEmpty {
                Divider()
                    .padding(.horizontal, 12)
                results
            }
        }
        .frame(width: 500)
        .clipShape(shape)
        .paletteGlass(in: shape)
        // Lifted well clear of the canvas. The scrim under it is dark, and without a
        // shadow the palette read as a lighter patch of it rather than as a thing on top.
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
        // The list arriving under the field is a height change, and it is animated as one
        // rather than popping — a shorter, flatter spring than the palette arrives on.
        .animation(.spring(duration: 0.22, bounce: 0.08), value: query.isEmpty)
        // ⌘K closes what ⌘K opened. The menu item toggles it and normally gets the key
        // first; this catches the press if the menu did not — a sheet's key window has no
        // terminal in it, so a shortcut on a view is safe here in a way it is not in a pane.
        .background {
            Button("") { isPresented = false }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .onAppear {
            queryFocused = true
            selection = matches.first?.id
            // Asked twice: the overlay appears while a terminal is still first responder,
            // and the first request can land before the field is in the responder chain.
            DispatchQueue.main.async { queryFocused = true }
        }
        .onChange(of: query) { selection = matches.first?.id }
        // Esc cancels any transient mode.
        .onExitCommand { isPresented = false }
    }

    /// The matches. Left out of the tree entirely while the query is empty — a scroll
    /// view with no rows still claims its full height.
    ///
    /// A `ScrollView` of rows rather than a `List`. `List` owns its selection drawing and
    /// on macOS that is a square band edge to edge, which cannot be rounded, inset, or
    /// told apart from a hover. Rows drawn by hand get the same rounded plate every other
    /// selected thing in this app wears, and the keyboard is wired by hand to match.
    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(matches) { command in
                        PaletteRow(command: command,
                                   isSelected: selection == command.id,
                                   isEnabled: command.isEnabled(store)) {
                            run(command)
                        }
                        .id(command.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Sized to the matches, up to a cap: three hits should not sit at the top of
            // a tall empty box, and forty should scroll rather than reach the window edge.
            .frame(height: min(CGFloat(matches.count) * PaletteRow.height + 12, 340))
            // An arrow key that lands the selection below the fold brings it into view.
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    /// ↑ and ↓ move the selection from the field, so the caret never has to leave it.
    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selection } ?? -1
        let next = min(max(current + offset, 0), matches.count - 1)
        selection = matches[next].id
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

/// One command in the results: its title, its binding, and a rounded plate when it is
/// the selection or under the pointer. Selection is the stronger of the two, and the two
/// never merge — the pointer resting on a row does not move the keyboard's choice.
private struct PaletteRow: View {
    let command: AppCommand
    let isSelected: Bool
    let isEnabled: Bool
    let run: () -> Void
    @State private var isHovering = false

    /// The row's height including its gap, so the list can size itself to a count.
    static let height: CGFloat = 34

    var body: some View {
        HStack {
            Text(command.title)
                .foregroundStyle(isEnabled ? Token.Colour.label : Token.Colour.tertiaryLabel)
            Spacer()
            if let binding = command.defaultBinding {
                Text(binding.display)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.secondaryLabel)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height - 2)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Token.Colour.label.opacity(isSelected ? 0.12 : (isHovering ? 0.06 : 0)))
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: run)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private extension View {
    /// Glass for the palette, with the opaque fallback Reduce Transparency asks for.
    ///
    /// Not `ultraChromeGlass`: that draws in a `ConcentricRectangle`, which takes its
    /// corners from the container it sits in, and the palette sits in no container — it
    /// floats over the whole window and needs a radius of its own.
    @ViewBuilder
    func paletteGlass(in shape: some InsettableShape) -> some View {
        if Token.Environment_.reduceTransparency {
            background(Token.Colour.tileBackground, in: shape)
                .overlay(shape.strokeBorder(Token.Colour.separator, lineWidth: 1))
        } else {
            glassEffect(.regular, in: shape)
        }
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
