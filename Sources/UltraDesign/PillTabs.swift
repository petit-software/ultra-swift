import SwiftUI

/// How much room a `PillTabs` takes.
///
/// The shapes are identical; only the type and the padding differ, so the two sizes read as
/// one control seen from different distances. A top-level type rather than one nested in
/// `PillTabs`, which is generic: nested, every element type would have had a `Size` of its
/// own, and a function taking "a pill size" could not be written.
public enum PillTabSize {
    /// A sheet or a settings pane, where the switch is the thing being looked at.
    case regular
    /// A tile's own chrome, where it sits in a header beside a path and a pair of counts.
    /// Mono, because everything else in that band is.
    case small

    var font: Font {
        switch self {
        case .regular: Token.Type_.body
        case .small: Token.Type_.monoSmall
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: 18
        case .small: 9
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .regular: 7
        case .small: 2.5
        }
    }
}

/// The app's tab switch: a row of pills, one of them washed.
///
/// ONE background colour in the whole control — the selected pill wears a neutral wash and the
/// unselected ones wear nothing. A filled track behind a filled pill was two greys arguing
/// about which of them meant "selected", and an accent fill on top of that was a third, and
/// unreadable besides: this app's accent defaults to white. The WEIGHT and the label colour
/// carry the rest, both from system colours, so the selection reads in either appearance and
/// under Increase Contrast.
///
/// Not `Picker(.segmented)`, which is what this replaces in the tiles. A segmented control is
/// a chunk of opaque AppKit chrome with its own bezel and its own idea of a background, and on
/// a pane made of glass it reads as a control panel bolted to the surface. `PickerStyle` cannot
/// be conformed to from outside SwiftUI, so a view is the only way to have one switch.
///
/// It grew out of the New Project sheet, which had this control written into it, and became
/// shared the moment a second place wanted the same thing smaller — see `PillTabSize`.
public struct PillTabs<Value: Hashable>: View {
    private let values: [Value]
    private let size: PillTabSize
    private let title: (Value) -> String
    @Binding private var selection: Value

    public init(_ values: [Value],
                selection: Binding<Value>,
                size: PillTabSize = .regular,
                title: @escaping (Value) -> String) {
        self.values = values
        self._selection = selection
        self.size = size
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                // A real `Button` per pill, and that is the keyboard story: with Full
                // Keyboard Access on, Tab reaches each one in visual order and Space picks
                // it — the same way the tabs of a `TabView` behave. A tap gesture on a
                // capsule would have looked identical and been unreachable.
                Button {
                    withAnimation(Token.Motion.structuralRespectingPreferences) {
                        selection = value
                    }
                } label: {
                    Pill(text: title(value), isSelected: selection == value, size: size)
                }
                .buttonStyle(.plain)
                // Said to VoiceOver rather than left to be inferred from a weight and a
                // wash, neither of which it can see.
                .accessibilityAddTraits(selection == value ? [.isButton, .isSelected]
                                                           : .isButton)
            }
        }
    }
}

/// One pill, in its own view: the label's chain — font, weight, colour, two paddings and a
/// conditional background — is more than the type checker will infer inside a `ForEach` inside
/// a `Button` label, and it says so by timing out rather than by failing.
private struct Pill: View {
    let text: String
    let isSelected: Bool
    let size: PillTabSize

    var body: some View {
        Text(text)
            .font(size.font)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundStyle(isSelected ? Token.Colour.label : Token.Colour.secondaryLabel)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background { background }
            .contentShape(.capsule)
    }

    @ViewBuilder
    private var background: some View {
        if isSelected { Capsule().fill(Token.Colour.selectionWash) }
    }
}

#Preview("Pill tabs", traits: .fixedLayout(width: 420, height: 140)) {
    struct Demo: View {
        @State private var big = "New Folder"
        @State private var small = "Working tree"

        var body: some View {
            VStack(spacing: 20) {
                PillTabs(["New Folder", "Clone Repository"], selection: $big) { $0 }
                PillTabs(["Working tree", "Staged"], selection: $small, size: .small) { $0 }
            }
            .padding(20)
        }
    }
    return Demo()
}
