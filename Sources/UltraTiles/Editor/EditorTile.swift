import AppKit
import SwiftUI
import UltraDesign

/// A minimal text editor in a pane, holding as many files and diffs as you throw at it.
///
/// The tab strip is what makes Git and the file tree usable from here: clicking four changed
/// files fills ONE pane rather than splitting four off a canvas with room for none of them.
/// See `EditorSessions`, which owns what is open.
public struct EditorTile: View {
    @State private var sessions: EditorSessions
    private let context: TileContext

    public init(context: TileContext, sessions: EditorSessions) {
        self.context = context
        _sessions = State(initialValue: sessions)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Absent rather than empty with nothing open: a bare strip over "Nothing open"
            // is a band of chrome labelling nothing.
            if !sessions.isEmpty {
                EditorTabStrip(sessions: sessions)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tileFooter { footer }
    }

    @ViewBuilder
    private var content: some View {
        if let session = sessions.selected {
            switch session.content {
            case .file(let document):
                FilePane(document: document, save: { save(session) })
                    // Keyed, so a new file gets a text view of its own: the caret is put in
                    // a NEW file as its view is made, and a view handed on from the tab
                    // before it would never be made.
                    .id(session.id)
            case .diff(let diff):
                DiffView(session: diff)
                    // Keyed for a different reason: a diff is fetched by the view showing
                    // it, as that view appears. One view handed from diff to diff appeared
                    // once, so every diff after the first sat on "Loading…".
                    .id(session.id)
            }
        } else {
            // Only the line. New and Open are in the footer, which is there in every state
            // of this tile — a second pair of them here was the same two controls twice.
            EmptyTileState(icon: "doc.text", title: "Nothing open")
        }
    }

    private var footer: some View {
        // The FULL path of what is showing. A tab has room only for a name, and two files
        // called `index.ts` are the normal case in any real project.
        TileFooter(summary: sessions.selected.map(summary(for:)) ?? "No file",
                   truncation: .head) {
            TileFooterButton(symbol: "plus.circle", help: "New file (⌃⌘N)") { sessions.newFile() }
            TileFooterButton(symbol: "folder", help: "Open another file") { openPanel() }
            if let session = sessions.selected,
               case .file(let document) = session.content, !document.isBinary {
                // A new file can be saved while it is still empty: that is how a file gets
                // made, and "nothing to save" would be wrong about one that is not on disk.
                TileFooterButton(symbol: "square.and.arrow.down", help: "Save (⌘S)",
                                 isEnabled: document.isDirty || document.isUntitled) { save(session) }
            }
            if sessions.selected?.isDirty == true {
                Circle()
                    .fill(Token.Colour.accent)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
    }

    private func summary(for session: EditorSession) -> String {
        session.isUntitled ? "\(session.title) — not saved yet" : TileFactory.abbreviate(session.path)
    }

    /// ⌘S and the footer's button. A file that has a place on disk goes back to it; a new
    /// one asks where, starting in the project's `.ultra/`.
    private func save(_ session: EditorSession) {
        guard case .file(let document) = session.content else { return }
        guard document.isUntitled else { document.save(); return }

        let folder = EditorDocument.defaultFolder(in: context.projectRoot)
        // The panel can only open on a folder that exists. One made for the occasion is
        // taken away again if the save is called off, so cancelling leaves no trace.
        let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
            && (try? FileManager.default.createDirectory(at: folder,
                                                         withIntermediateDirectories: true)) != nil
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = EditorDocument.suggestedName(in: folder)
        // `.ultra` is a dot folder, and a panel that opens inside one while hiding them
        // cannot show where it is.
        panel.showsHiddenFiles = true
        let saved = panel.runModal() == .OK
            && panel.url.map { sessions.save(session, to: $0) } == true
        if madeFolder, !saved,
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
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

// MARK: - Tabs

/// What is open, as a row of tabs along the top of the pane.
///
/// A row rather than a source list: a sidebar took a column off a pane that is already as
/// narrow as the user made it, and hid itself below 400pt — which is where most editor panes
/// live, beside a shell. A strip costs one line of height whatever the width, and scrolls
/// sideways when there is more open than fits, with the selected tab kept in view.
///
/// Files and diffs share the row in the order they were opened, told apart by icon. Two
/// sections made sense in a list with headers; in a strip they would be two strips.
private struct EditorTabStrip: View {
    let sessions: EditorSessions

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions.sessions) { session in
                        EditorTab(session: session,
                                  isSelected: session.id == sessions.selectedID,
                                  select: { sessions.select(session.id) },
                                  close: { sessions.close(session.id) })
                            .id(session.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: sessions.selectedID, initial: true) { _, selected in
                // Selected from the keyboard (⇧⌘]) or by another pane opening a file here,
                // the tab may be off the end of the row. Bring it in.
                guard let selected else { return }
                withAnimation(Token.Motion.structuralRespectingPreferences) {
                    proxy.scrollTo(selected)
                }
            }
        }
        .overlay(alignment: .bottom) { Divider().overlay(Token.Colour.divider) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open files and changes")
    }
}

/// One tab: the file's icon, its name, and its unsaved dot — or, under the pointer, the
/// close control in the icon's place.
///
/// Same arrangement as the session belt's tabs, one size down: ONE slot for icon and X, so
/// the name never moves as the pointer crosses the tab, and the selection carried by a
/// neutral wash and the label colour rather than a weight change that would make the tab
/// wider and slide every tab after it along the row.
private struct EditorTab: View {
    let session: EditorSession
    let isSelected: Bool
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
                    Image(systemName: session.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Token.Colour.accent : Token.Colour.secondaryLabel)
                }
            }
            .frame(width: 14, height: 14)

            Text(session.title)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(isSelected ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            if session.isDirty {
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
        // keyboard path is ⇧⌘] / ⇧⌘[ (Pane ▸ Editor ▸ Next / Previous), which is what makes
        // a strip of tap targets an acceptable control in this app.
        .onTapGesture(perform: select)
        .help(session.isUntitled ? "Not saved yet" : session.path)
        .contextMenu {
            Button("Close", action: close)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(session.isDiff ? "Change" : "File"), \(session.title)")
        .accessibilityAction(named: "Close", close)
        .accessibilityAction { select() }
    }
}

// MARK: - File content

/// One file's text, plus whatever the document has to say about the state of it on disk.
private struct FilePane: View {
    @Bindable var document: EditorDocument
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let notice = document.notice { noticeBar(notice) }
            if document.isBinary {
                // WHICH file is the footer's job — it carries the full path in every state
                // of this tile, including this one.
                EmptyTileState(icon: "doc.questionmark", title: "Not a text file")
            } else {
                // A new file takes the caret as it appears: it was asked for in order to be
                // typed into, and nothing else in the pane wants the keyboard.
                CodeTextView(text: $document.text,
                             language: language,
                             claimsFocus: { document.claimInitialFocus() }, onSave: save)
            }
        }
    }

    /// By name first; by shebang only for a file whose name says nothing, so that a
    /// `deploy` script with `#!/bin/sh` on top is coloured as shell. The text is read here
    /// only in that case: reading it for every file would redraw this view on every
    /// keystroke.
    private var language: CodeLanguage? {
        guard let url = document.url else { return nil }
        if let named = CodeLanguage.detect(path: url.path) { return named }
        return CodeLanguage.detect(shebang: document.text.prefix { !$0.isNewline })
    }

    private func noticeBar(_ notice: EditorDocument.Notice) -> some View {
        NoticeBar(symbol: icon(for: notice),
                  message: message(for: notice),
                  tint: notice == .conflict ? Color.orange.opacity(0.18)
                                            : Token.Colour.accentWash,
                  // Closing a conflict keeps YOUR edits: the buffer is left exactly as it
                  // is and the strip goes away. The one thing that drops them is Reload,
                  // which is why it is the only other control here.
                  dismiss: { document.dismissNotice() }) {
            if notice == .conflict {
                Button("Reload") { document.revert(); document.externalChange() }
            }
        }
    }

    private func icon(for notice: EditorDocument.Notice) -> String {
        switch notice {
        case .reloadedFromDisk: "arrow.clockwise.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
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

#Preview("Editor with tabs", traits: .fixedLayout(width: 620, height: 380)) {
    let sessions = EditorSessions()
    sessions.open(.file(URL(fileURLWithPath: "/tmp/Package.swift")))
    sessions.open(.file(URL(fileURLWithPath: "/tmp/README.md")))
    sessions.newFile()
    return EditorTile(context: .inert(), sessions: sessions)
}
