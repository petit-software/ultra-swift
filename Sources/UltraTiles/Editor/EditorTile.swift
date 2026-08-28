import AppKit
import SwiftUI
import UltraDesign

/// A minimal text editor in a pane, holding as many files and diffs as you throw at it.
///
/// The sidebar is what makes Git and the file tree usable from here: clicking four changed
/// files fills ONE pane rather than splitting four off a canvas with room for none of them.
/// See `EditorSessions`, which owns what is open.
public struct EditorTile: View {
    @State private var sessions: EditorSessions
    /// Dragged by the divider. View state rather than a preference: it is the shape of THIS
    /// pane, and two editor panes of different widths want different answers.
    @State private var sidebarWidth: CGFloat = 180
    private let context: TileContext

    public init(context: TileContext, sessions: EditorSessions) {
        self.context = context
        _sessions = State(initialValue: sessions)
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if showsSidebar(in: geometry.size.width) {
                    EditorSidebar(sessions: sessions)
                        .frame(width: sidebarWidth)
                    SidebarDivider(width: $sidebarWidth, available: geometry.size.width)
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tileFooter { footer }
        .tileHeaderInset()
    }

    /// Hidden when there is nothing open, and hidden when the pane is simply too narrow to
    /// carry both columns.
    ///
    /// A pane can be dragged down to 160pt — `LayoutMetrics.minPaneSize` — and a sidebar in
    /// one of those leaves a content column too thin to read a line of code in. The override
    /// is silent on purpose: a sidebar that insists on being shown in a pane that cannot hold
    /// it costs the user the thing they were actually looking at.
    private func showsSidebar(in width: CGFloat) -> Bool {
        sessions.isSidebarVisible && !sessions.isEmpty && width >= sidebarWidth + 220
    }

    @ViewBuilder
    private var content: some View {
        if let session = sessions.selected {
            switch session.content {
            case .file(let document): FilePane(document: document)
            case .diff(let diff): DiffView(session: diff)
            }
        } else {
            EmptyTileState(icon: "doc.text",
                           title: "Nothing open",
                           detail: "Open a file, or click one in a File Tree or Git pane")
                .overlay(alignment: .bottom) {
                    Button("Open File…") { openPanel() }
                        .padding(.bottom, 26)
                }
        }
    }

    private var footer: some View {
        // The FULL path of what is showing. The sidebar has room only for a name, and two
        // files called `index.ts` are the normal case in any real project.
        TileFooter(summary: sessions.selected.map { TileFactory.abbreviate($0.path) } ?? "No file",
                   truncation: .head) {
            TileFooterButton(symbol: "sidebar.left", help: "Show or hide the sidebar (⌘⌥S)",
                             isEnabled: !sessions.isEmpty) {
                sessions.isSidebarVisible.toggle()
            }
            TileFooterButton(symbol: "folder", help: "Open another file") { openPanel() }
            if case .file(let document)? = sessions.selected?.content, !document.isBinary {
                TileFooterButton(symbol: "square.and.arrow.down", help: "Save (⌘S)",
                                 isEnabled: document.isDirty) { document.save() }
            }
            if sessions.selected?.isDirty == true {
                Circle()
                    .fill(Token.Colour.accent)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        // Several at once, because the editor can now hold several at once. Picking files
        // one dialog at a time was a limit of the pane, not of the panel.
        panel.allowsMultipleSelection = true
        panel.directoryURL = context.root
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { sessions.open(.file(url)) }
    }
}

// MARK: - Sidebar

/// What is open, as a source list.
///
/// A real `List` in `.sidebar` style rather than a row of tabs: the system draws the
/// selection and the section headers, it still works when twelve things are open where a row
/// of tabs would have squeezed every label to nothing, and a full name fits on a line
/// instead of being truncated to `ind…tsx`.
///
/// Files and changes are separate sections because they are separate kinds of work — editing
/// a file and reading a diff — and a flat list of the two mixed together makes you read every
/// icon to find either.
private struct EditorSidebar: View {
    @Bindable var sessions: EditorSessions

    private var selection: Binding<EditorSession.ID?> {
        Binding(get: { sessions.selectedID },
                set: { if let id = $0 { sessions.select(id) } })
    }

    var body: some View {
        List(selection: selection) {
            section("Files", sessions.files)
            section("Changes", sessions.diffs)
        }
        .listStyle(.sidebar)
        // The pane's own surface shows through. A list painting its own background is an
        // opaque rectangle sitting on glass, which is the one thing a pane here never is.
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Open files and changes")
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [EditorSession]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { session in
                    SidebarRow(session: session) { sessions.close(session.id) }
                        .tag(session.id)
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let session: EditorSession
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.symbol)
                .font(.system(size: 10))
                .foregroundStyle(Token.Colour.accent)
                .frame(width: 14)

            Text(session.title)
                .font(Token.Type_.monoSmall)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // The dot becomes the close control on hover, in the same place — the
            // arrangement every source list uses, and why a row needs room for only one.
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Token.Colour.secondaryLabel)
                .help("Close")
            } else if session.isDirty {
                Circle()
                    .fill(Token.Colour.accent)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes")
            }
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .help(session.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.isDiff ? "Change" : "File"), \(session.title)")
    }
}

/// The draggable edge of the sidebar.
///
/// Clamped so neither column can be dragged out of existence: below the lower bound the
/// names stop fitting, and past the upper one the code column is narrower than the list of
/// files pointing at it.
private struct SidebarDivider: View {
    @Binding var width: CGFloat
    let available: CGFloat

    var body: some View {
        Divider()
            .overlay(Token.Colour.divider)
            // A hairline is a 1pt target. The hit area is widened without moving the line,
            // the same trick the canvas dividers use.
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let upper = max(120, min(320, available - 220))
                                width = min(max(120, width + value.translation.width), upper)
                            }
                    )
            }
    }
}

// MARK: - File content

/// One file's text, plus whatever the document has to say about the state of it on disk.
private struct FilePane: View {
    @Bindable var document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            if let notice = document.notice { noticeBar(notice) }
            if document.isBinary {
                EmptyTileState(icon: "doc.questionmark",
                               title: "Not a text file",
                               detail: document.displayName)
            } else {
                CodeTextView(text: $document.text, onSave: { document.save() })
            }
        }
    }

    @ViewBuilder
    private func noticeBar(_ notice: EditorDocument.Notice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: notice))
            Text(message(for: notice)).lineLimit(2)
            Spacer(minLength: 4)
            if notice == .conflict {
                // Both ways out, named for what they do to YOUR edits.
                Button("Keep Mine") { document.dismissNotice() }
                Button("Reload") { document.revert(); document.externalChange() }
            } else {
                Button("Dismiss") { document.dismissNotice() }
            }
        }
        .buttonStyle(.plain)
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(notice == .conflict
                    ? Color.orange.opacity(0.18)
                    : Token.Colour.accent.opacity(0.12))
    }

    private func icon(for notice: EditorDocument.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "arrow.clockwise"
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon"
        }
    }

    private func message(for notice: EditorDocument.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "Reloaded — the file changed on disk"
        case .conflict: "Changed on disk while you were editing. Nothing was overwritten."
        case .failed(let reason): reason
        }
    }
}

#Preview("Editor", traits: .fixedLayout(width: 620, height: 380)) {
    EditorTile(context: .inert(), sessions: EditorSessions())
}
