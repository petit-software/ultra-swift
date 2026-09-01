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

    private var tint: SessionTint { SessionTint(storedValue: appearance.tint) }

    /// One width for both grids, taken from the catalogue: the symbol list is written in
    /// themed rows of `SessionSymbols.columns`, and a picker that laid it out any other
    /// width would show those rows broken across lines.
    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6),
                                count: SessionSymbols.columns)

    /// Five rows, plus enough of a sixth to show there is more below. The catalogue is
    /// twelve rows long now; laid out in full it made a popover taller than the sidebar
    /// row it hangs off.
    private static let symbolGridHeight: CGFloat = 178

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

            section("Color") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(SessionTint.allCases) { swatch in
                        Button { appearance.tint = swatch.rawValue } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    // A ring AROUND the swatch, not a tick inside it: a
                                    // checkmark on a yellow dot is invisible and on a dark
                                    // one it hides the colour being chosen.
                                    Circle()
                                        .strokeBorder(Token.Colour.label, lineWidth: 2)
                                        .padding(-3)
                                        .opacity(tint == swatch ? 1 : 0)
                                }
                                .frame(width: 28, height: 28)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(swatch.title)
                        .accessibilityLabel(swatch.title)
                        .accessibilityAddTraits(tint == swatch ? [.isSelected] : [])
                    }
                }
            }

            section("Symbol") {
                ScrollViewReader { proxy in
                    ScrollView {
                        symbolGrid
                    }
                    .frame(height: Self.symbolGridHeight)
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear {
                        // A mark chosen from the bottom of the list would otherwise open
                        // to a grid with no selection anywhere in it, which reads as
                        // "nothing is chosen" rather than "scroll down".
                        //
                        // After the first layout pass: a lazy grid has not built the row
                        // being scrolled to until it has one.
                        DispatchQueue.main.async {
                            proxy.scrollTo(appearance.symbol, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Dimmed rather than hidden on an untouched session: an item that appears and
            // disappears is one the user has to hunt for.
            Button("Reset to Default", action: reset)
                .disabled(!isCustomized)
        }
        .padding(14)
        .frame(width: 232)
        .onAppear { isNameFocused = true }
        // Closing by clicking away is as much a commit as pressing Return, so an emptied
        // field must not be able to leave a nameless row behind.
        .onDisappear { normalize() }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(SessionSymbols.all, id: \.self) { symbol in
                Button { appearance.symbol = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        // Deliberately NOT the chosen colour. A grid of glyphs all
                        // repainted on every swatch press turned choosing a colour
                        // into the whole popover flashing, and it left the grid
                        // answering a question — "what colour is this?" — that the
                        // swatches above already answer. This grid picks a SHAPE;
                        // the row behind the popover is where the colour shows.
                        .foregroundStyle(Token.Colour.label)
                        .frame(width: 28, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Token.Colour.label.opacity(0.12))
                                .opacity(appearance.symbol == symbol ? 1 : 0)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
                .accessibilityAddTraits(appearance.symbol == symbol ? [.isSelected] : [])
                // The anchor `scrollTo` aims at when the popover opens on a mark
                // that sits below the fold.
                .id(symbol)
            }
        }
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
