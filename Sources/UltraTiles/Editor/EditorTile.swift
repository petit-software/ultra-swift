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

/// What is open, as the tile's row of tabs — `TileTabStrip`, which the browser shares.
///
/// Files and diffs share the row in the order they were opened, told apart by icon. Two
/// sections made sense in a list with headers; in a strip they would be two strips.
///
/// A view of its own rather than a few lines in the tile's body, so a title or an unsaved
/// dot changing redraws the strip and not the editor under it.
private struct EditorTabStrip: View {
    let sessions: EditorSessions

    var body: some View {
        // The keyboard path along the row is ⇧⌘] / ⇧⌘[ (Pane ▸ Editor ▸ Next / Previous).
        TileTabStrip(tabs: sessions.sessions.map { session in
                         TileTab(id: session.id,
                                 title: session.title,
                                 symbol: session.symbol,
                                 help: session.isUntitled ? "Not saved yet" : session.path,
                                 isDirty: session.isDirty,
                                 accessibilityLabel: "\(session.isDiff ? "Change" : "File"), \(session.title)")
                     },
                     selectedID: sessions.selectedID,
                     label: "Open files and changes",
                     select: { sessions.select($0) },
                     close: { sessions.close($0) })
    }
}

// MARK: - File content

/// One file's text, plus whatever the document has to say about the state of it on disk.
private struct FilePane: View {
    @Bindable var document: EditorDocument
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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
        // Closing a conflict keeps YOUR edits: the buffer is left exactly as it is and the
        // toast goes away. The one thing that drops them is Reload, which is why it is the
        // only other control there.
        .tileToast(document.notice.map(notice(for:)), dismiss: { document.dismissNotice() }) {
            if document.notice == .conflict {
                Button("Reload") { document.revert(); document.externalChange() }
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

    private func notice(for notice: EditorDocument.Notice) -> TileNotice {
        switch notice {
        case .reloadedFromDisk: .reloadedFromDisk
        case .conflict: .conflict
        case .failed(let reason): .failed(reason)
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
