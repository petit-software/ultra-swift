import SwiftUI
import UltraCore
import UltraDesign
import UltraTiles

/// The colour and the symbol a session's sidebar row is drawn with.
///
/// Split out of `SessionCustomizer` when a SECOND place needed to ask the same question —
/// the new-project sheet, which chooses a row's look before the project exists. Two copies
/// of a swatch grid is how the two end up with different swatches, a different selection
/// ring, and a symbol grid that scrolls to the chosen mark in one of them and not the other.
struct SessionAppearancePicker: View {
    /// Bound, not passed: whatever is showing the row — the sidebar behind a popover, or the
    /// preview in the new-project sheet — redraws as the user tries colours, which is the
    /// whole reason to make this a live picker rather than a form with an OK button.
    @Binding var appearance: SessionAppearance

    /// One width for both grids, taken from the catalogue: the symbol list is written in
    /// themed rows of `SessionSymbols.columns`, and a picker that laid it out any other
    /// width would show those rows broken across lines.
    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6),
                                count: SessionSymbols.columns)

    /// Five rows, plus enough of a sixth to show there is more below. The catalogue is
    /// twelve rows long; laid out in full it made a popover taller than the sidebar row it
    /// hangs off.
    static let symbolGridHeight: CGFloat = 178

    /// The width both callers give the picker, so the grids are never re-flowed.
    static let width: CGFloat = 232
    /// What the six fixed columns and their gaps actually measure — the width both grids
    /// are held to, so neither can centre itself in the picker.
    static let gridWidth: CGFloat = CGFloat(SessionSymbols.columns) * 28
        + CGFloat(SessionSymbols.columns - 1) * 6
    /// The padding both callers wrap the picker in — what the symbol grid's scroll view
    /// borrows on its trailing side so its bar can sit at the popover's edge.
    static let popoverPadding: CGFloat = 14
    /// How far in from that edge the bar sits.
    static let scrollBarEdgeInset: CGFloat = 6

    private var tint: SessionTint { SessionTint(storedValue: appearance.tint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Color") {
                HStack(spacing: 0) {
                    colourGrid.frame(width: Self.gridWidth)
                    Spacer(minLength: 0)
                }
            }
            section("Symbol") {
                ScrollViewReader { proxy in
                    ScrollView {
                        // LEADING, at the grid's own width. A scroll view offers its content
                        // the full width and a grid of fixed columns centres itself in
                        // whatever it is given — which put the symbols a margin's worth to
                        // the right of where the colours sit, and the last column under the
                        // scroll bar. Sized to its six columns and pushed to the leading
                        // edge by the spacer, the grid starts where the colours do and the
                        // bar has the rest of the width to itself.
                        HStack(spacing: 0) {
                            symbolGrid.frame(width: Self.gridWidth)
                            Spacer(minLength: 0)
                        }
                    }
                    // The panes' own scroller, not the system's: with "Show scroll bars:
                    // Always" the system one is a legacy scroller that reserves a grey
                    // gutter down the grid's right edge — the same defect every pane
                    // already solved, showing up in the one scroll view that had not.
                    //
                    // At the popover's own edge, not the grid's. The scroll view reaches out
                    // through the popover's padding, and the bar sits 6pt in from the edge
                    // it reaches — beside the symbols, with the whole margin between.
                    .tileScrollBar(sideInset: Self.scrollBarEdgeInset)
                    .frame(height: Self.symbolGridHeight)
                    .padding(.trailing, -Self.popoverPadding)
                    .scrollBounceBehavior(.basedOnSize)
                    .onAppear {
                        // A mark chosen from the bottom of the list would otherwise open to
                        // a grid with no selection anywhere in it, which reads as "nothing
                        // is chosen" rather than "scroll down".
                        //
                        // After the first layout pass: a lazy grid has not built the row
                        // being scrolled to until it has one.
                        DispatchQueue.main.async {
                            proxy.scrollTo(appearance.symbol, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var colourGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(SessionTint.allCases) { swatch in
                Button { appearance.tint = swatch.rawValue } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 18, height: 18)
                        .overlay {
                            // A ring AROUND the swatch, not a tick inside it: a checkmark on
                            // a yellow dot is invisible and on a dark one it hides the
                            // colour being chosen.
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

    private var symbolGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(SessionSymbols.all, id: \.self) { symbol in
                Button { appearance.symbol = symbol } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        // Deliberately NOT the chosen colour. A grid of glyphs all repainted
                        // on every swatch press turned choosing a colour into the whole
                        // popover flashing, and it left the grid answering a question —
                        // "what colour is this?" — that the swatches above already answer.
                        // This grid picks a SHAPE; the row is where the colour shows.
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
                // The anchor `scrollTo` aims at when the picker opens on a mark below the
                // fold.
                .id(symbol)
            }
        }
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

/// A session's row as it will look: its symbol, in its colour. Used as the preview on the
/// new-project sheet's picker, so what the sheet promises and what the sidebar draws come
/// from one place.
struct SessionIconPreview: View {
    let appearance: SessionAppearance

    var body: some View {
        Image(systemName: SessionSymbols.resolved(appearance.symbol))
            .font(Token.Type_.tileTitle)
            .foregroundStyle(SessionTint(storedValue: appearance.tint).color)
            // The same fixed box the sidebar row gives it, so a wide symbol and a narrow one
            // do not shift the words beside them.
            .frame(width: 20)
    }
}

#Preview("Appearance picker") {
    @Previewable @State var appearance = SessionAppearance(symbol: "flame.fill", tint: "orange")
    SessionAppearancePicker(appearance: $appearance)
        .padding(14)
        .frame(width: SessionAppearancePicker.width)
}
