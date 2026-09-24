import SwiftUI
import UltraCanvas
import UltraDesign
import UltraTiles

@MainActor
@Observable
final class UIState {
    var isPaletteShown = false
    /// The session whose customise sheet is open, or nil.
    ///
    /// Window state rather than row state, because the sheet has several ways in — a sidebar
    /// row's context menu, a belt tab's, and File ▸ Session ▸ Customize Session… — and a
    /// flag owned by one row could only be reached from that row. A context menu is a
    /// *view* of the command registry, never the only way to do something; see the
    /// `keyboard-first` skill.
    ///
    /// An ID rather than a Bool read through "the selected row". Customizing a session that
    /// is not selected selects it too, and the selection change used to clear the Bool in
    /// the same update that set it — the sheet never opened, only the tab changed. Naming
    /// the session means nothing about the selection can take the sheet away from it.
    var customizingSessionID: UUID?
    /// Whether the new-project sheet is up.
    ///
    /// Window state rather than sidebar state, for the same reason as the flag above: there
    /// are two ways in — the sidebar's `+` and File ▸ New Project… — and a flag owned by the
    /// bar could only be reached by the first. The menu item is not a convenience; it is the
    /// keyboard path, and a command reachable only from a control is the anti-pattern the
    /// `keyboard-first` skill names outright.
    var isCreatingProject = false
    /// Whether the session tab belt is on screen in place of the sidebar. Window state
    /// because it decides WHICH view presents the customise sheet: the sidebar's selected
    /// row, or the belt's selected tab. Both answering the one flag would stack two sheets.
    var showsTabBelt = false
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
                // The same 18pt slot the rows give their symbols, so the ⌘ and the column
                // of icons under it share an axis, and the field's text lines up with the
                // titles below it.
                Image(systemName: "command")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .frame(width: PaletteRow.symbolWidth)
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

            // No rule between the field and the rows: the first row's plate is enough of
            // a boundary, and a line across the glass read as a second, narrower box.
            if !query.isEmpty {
                if matches.isEmpty {
                    noMatches
                } else {
                    results
                }
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
        // ⌘K closes what ⌘K opened, and the MENU ITEM alone does it. There used to be a
        // hidden button here with the same shortcut, from when the palette was a sheet
        // and the menu could not reach it. As an overlay it can — and the key window's
        // views get a key equivalent BEFORE the menu, which then fires anyway: the
        // button closed the palette, the close handed the keyboard to the terminal, and
        // the menu toggled it straight back open with the caret gone. Two handlers for
        // one key is one too many.
        .onAppear {
            queryFocused = true
            selection = matches.first?.id
        }
        // Asked again until it lands. The overlay appears while a terminal is still first
        // responder, the first request can land before the field is in the responder
        // chain, and the palette's arrival can re-drive the canvas underneath — which
        // used to answer by taking the keyboard back. Bounded, so a field that cannot be
        // focused (the window lost key) does not ask forever.
        .task {
            for _ in 0..<8 where !queryFocused {
                queryFocused = true
                try? await Task.sleep(for: .milliseconds(40))
            }
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
            // The panes' own scroll bar, for the reason the panes have one: the system
            // scroller reserves width the moment it appears, so the shortcut column
            // jumped left on the first scroll and back on the next. Hiding the indicators
            // was not enough — macOS still flashes its scroller while scrolling — and the
            // pane bar is the one that already solved this, so the palette wears the same.
            .tileScrollBar()
            // Sized to the matches, up to a cap: three hits should not sit at the top of
            // a tall empty box, and forty should scroll rather than reach the window edge.
            .frame(height: min(CGFloat(matches.count) * PaletteRow.height + 12, 340))
            // An arrow key that lands the selection below the fold brings it into view.
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    /// A query that matches nothing says so, rather than the list silently vanishing —
    /// which looks the same as the palette not having heard the keystroke. One row tall,
    /// dimmed, and laid out on the same grid as a result so nothing jumps when the next
    /// character finds something again.
    private var noMatches: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .frame(width: PaletteRow.symbolWidth)
            Text("No command found")
            Spacer()
        }
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 18)
        .frame(height: PaletteRow.height - 2)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
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

/// One command in the results: its symbol, its title, its binding, and a rounded plate
/// when it is the selection or under the pointer. Selection is the stronger of the two,
/// and the two never merge — the pointer resting on a row does not move the keyboard's
/// choice.
private struct PaletteRow: View {
    let command: AppCommand
    let isSelected: Bool
    let isEnabled: Bool
    let run: () -> Void
    @State private var isHovering = false

    /// The row's height including its gap, so the list can size itself to a count.
    static let height: CGFloat = 34
    /// The symbol's slot. Shared with the field's ⌘ so the two columns line up.
    static let symbolWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            // A fixed slot rather than the glyph's own width, so titles line up down the
            // list whatever mix of narrow arrows and wide rectangles sits above them.
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? Token.Colour.secondaryLabel : Token.Colour.tertiaryLabel)
                .frame(width: Self.symbolWidth)
            Text(command.title)
                .foregroundStyle(isEnabled ? Token.Colour.label : Token.Colour.tertiaryLabel)
            Spacer()
            if let binding = command.defaultBinding {
                Text(binding.display)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.secondaryLabel)
            }
        }
        // 8 inside the plate and 10 outside it: 18 from the palette's edge, which is where
        // the field's ⌘ sits, so the symbols form one column with it.
        .padding(.horizontal, 8)
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
