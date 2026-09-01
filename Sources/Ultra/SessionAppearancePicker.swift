import SwiftUI
import UltraCore
import UltraDesign

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

    private var tint: SessionTint { SessionTint(storedValue: appearance.tint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Color") { colourGrid }
            section("Symbol") {
                ScrollViewReader { proxy in
                    ScrollView {
                        symbolGrid
                    }
                    .frame(height: Self.symbolGridHeight)
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
