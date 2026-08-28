import AppKit
import SwiftUI
import UltraCanvas
import UltraDesign
import UltraTerminal

/// The window's sessions, as the sidebar column of a `NavigationSplitView`.
///
/// This is where macOS window tabs used to be. A tab bar hides itself at one tab, has room
/// for a name only until there are about four, and lives in the one strip the traffic lights
/// already own. A sidebar has none of those problems: visible at one session, good for a
/// dozen, and each row has room to say which project it is and how much is in it.
///
/// Deliberately just the LIST. The column, its width, its collapse behaviour, the traffic
/// lights sitting over it, the material behind it and the toggle button in the toolbar are
/// all `NavigationSplitView`'s — an earlier version hand-rolled every one of those out of an
/// `HStack` and a spacer, which is how you end up maintaining a worse copy of AppKit.
struct SessionSidebar: View {
    @Bindable var sessions: SessionList

    private var selection: Binding<UUID?> {
        Binding(get: { sessions.selectedID },
                set: { if let id = $0 { sessions.select(id) } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(sessions.sessions, id: \.workspaceID) { store in
                SessionRow(store: store,
                           canClose: sessions.canCloseSelected,
                           close: { sessions.close(store.workspaceID) })
                    .tag(store.workspaceID)
            }
        }
        // One kind of thing in one group, so a header would be a word explaining a list that
        // explains itself. The editor's sidebar has two sections because it holds two kinds.
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        .accessibilityLabel("Sessions")
    }
}

private struct SessionRow: View {
    let store: LayoutStore
    let canClose: Bool
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.split.2x1")
                .foregroundStyle(Token.Colour.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(store.workspaceTitle)
                    .lineLimit(1)
                // How much is in it. The one thing a row can say that tells two checkouts of
                // the same project apart at a glance.
                Text("\(store.tree.paneCount) pane\(store.tree.paneCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isHovering, canClose {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close session")
            }
        }
        .onHover { isHovering = $0 }
        .help(store.workspaceSubtitle ?? store.workspaceTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session, \(store.workspaceTitle), \(store.tree.paneCount) panes")
    }
}
