import SwiftUI
import UltraDesign

/// One tab in a tile's strip: what it is called, and what it says about itself.
struct TileTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let symbol: String
    /// The tooltip: the whole of what the title had no room for — a path, a URL.
    let help: String
    /// An accent dot after the title: unsaved changes.
    var isDirty = false
    /// What VoiceOver calls it, kind first: "File, Package.swift".
    let accessibilityLabel: String
}

/// What a tile has open, as a row of tabs along the top of the pane.
///
/// A row rather than a source list: a sidebar took a column off a pane that is already as
/// narrow as the user made it, and hid itself below 400pt — which is where most panes
/// live, beside a shell. A strip costs one line of height whatever the width, and scrolls
/// sideways when there is more open than fits, with the selected tab kept in view.
///
/// Shared by the editor and the browser, so a tab is the same object in both: the editor
/// had the only one, and a browser's written beside it would have been a second size and
/// a second hover within the week.
struct TileTabStrip<ID: Hashable>: View {
    let tabs: [TileTab<ID>]
    let selectedID: ID?
    /// What VoiceOver calls the row.
    let label: String
    /// File names keep both ends; a page's title keeps its start.
    var truncation: Text.TruncationMode = .middle
    /// The line under the strip. Off where the strip sits on more chrome of the tile's own
    /// and the line belongs under all of it.
    var showsDivider = true
    let select: (ID) -> Void
    let close: (ID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TileTabView(tab: tab,
                                    isSelected: tab.id == selectedID,
                                    truncation: truncation,
                                    select: { select(tab.id) },
                                    close: { close(tab.id) })
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: selectedID, initial: true) { _, selected in
                // Selected from the keyboard or by another pane opening something here,
                // the tab may be off the end of the row. Bring it in.
                guard let selected else { return }
                withAnimation(Token.Motion.structuralRespectingPreferences) {
                    proxy.scrollTo(selected)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showsDivider { Divider().overlay(Token.Colour.divider) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// One tab: its icon, its name, and its unsaved dot — or, under the pointer, the close
/// control in the icon's place.
///
/// Same arrangement as the session belt's tabs, one size down: ONE slot for icon and X, so
/// the name never moves as the pointer crosses the tab, and the selection carried by a
/// neutral wash and the label colour rather than a weight change that would make the tab
/// wider and slide every tab after it along the row.
private struct TileTabView<ID: Hashable>: View {
    let tab: TileTab<ID>
    let isSelected: Bool
    let truncation: Text.TruncationMode
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if isHovering {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.label)
                    .help("Close")
                } else {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Token.Colour.accent : Token.Colour.secondaryLabel)
                }
            }
            .frame(width: 14, height: 14)

            Text(tab.title)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(isSelected ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)
                .truncationMode(truncation)
                .frame(maxWidth: 180)

            if tab.isDirty {
                Circle()
                    .fill(Token.Colour.accent)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background {
            if isSelected {
                Capsule().fill(Token.Colour.selectionWash)
            } else if isHovering {
                Capsule().fill(Token.Colour.selectionWash.opacity(0.5))
            }
        }
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        // A tap rather than a `Button`, so the close button inside keeps its own click. The
        // keyboard path is the tile's Next / Previous on the Pane menu, which is what makes
        // a strip of tap targets an acceptable control in this app.
        .onTapGesture(perform: select)
        .help(tab.help)
        .contextMenu {
            Button("Close", action: close)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAction(named: "Close", close)
        .accessibilityAction { select() }
    }
}

#Preview("Tile tab strip", traits: .fixedLayout(width: 420, height: 34)) {
    TileTabStrip(tabs: [TileTab(id: 1, title: "Package.swift", symbol: "doc.text",
                                help: "/tmp/Package.swift", accessibilityLabel: "File, Package.swift"),
                        TileTab(id: 2, title: "README.md", symbol: "doc.text",
                                help: "/tmp/README.md", isDirty: true,
                                accessibilityLabel: "File, README.md"),
                        TileTab(id: 3, title: "Sources/App.swift", symbol: "plusminus",
                                help: "/tmp/Sources/App.swift",
                                accessibilityLabel: "Change, App.swift")],
                 selectedID: 2, label: "Open files", select: { _ in }, close: { _ in })
}
