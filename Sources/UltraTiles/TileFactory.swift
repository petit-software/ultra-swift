import AppKit
import SwiftUI
import UltraChat
import UltraCore
import UltraLayout

/// Builds every pane that is NOT a shell.
///
/// Mirrors `ShellPaneFactory` exactly — the canvas asks for content by `PaneID` and gets a
/// view plus a record — so the canvas never learns that tiles and shells are different
/// things. Returns nil for a pane it does not own, and the caller falls through to shells.
@MainActor
public final class TileFactory {
    public var context: TileContext
    /// What each tile pane IS: restored from disk to begin with, then overwritten by every
    /// build. It is what a rebuild reads, which is how a retargeted tile comes back on the
    /// folder the user chose rather than on the one it was created with.
    private var records: [PaneID: PaneRecord]
    private var pendingKind: PaneRecord.Kind?
    private var hosts: [PaneID: NSView] = [:]

    /// A tile was pointed at a different folder and needs rebuilding on it. The app wires
    /// this to the store, because the factory has no idea what a canvas is.
    public var onRootChange: ((PaneID, PaneRecord) -> Void)?

    public init(context: TileContext, restoring records: [PaneID: PaneRecord] = [:]) {
        self.context = context
        self.records = records
    }

    /// The next pane created will be this kind. Consumed once, like `stageAgent` — a single
    /// "New File Tree" must not turn every later split into a file tree.
    public func stage(_ kind: PaneRecord.Kind?) { pendingKind = kind }

    /// Records for panes that do not exist yet. See `ShellPaneFactory.adopt(records:)`: a
    /// layout adopted from another project names panes this factory has never built, and
    /// the record is the only thing that says which of them are tiles.
    public func adopt(records: [PaneID: PaneRecord]) {
        self.records.merge(records) { _, new in new }
    }

    /// What the next editor pane should open on. Consumed once, like the kind.
    private var pendingRequest: EditorRequest?
    public func stage(open request: EditorRequest?) { pendingRequest = request }

    /// The open tabs of each editor pane.
    ///
    /// Held HERE rather than in the view, for the same reason a shell's PTY is: a pane is
    /// rebuilt whenever it is restored or converted, and a tab set living in `@State` would
    /// take every open file with it. It is also the handle something outside the pane needs
    /// — the Git tile, the file tree, an agent's `open` — to put a tab into an editor that
    /// already exists instead of splitting another pane off a full canvas.
    private var sessions: [PaneID: EditorSessions] = [:]

    /// This pane's tabs, or nil for a pane that is not an editor.
    public func editorSessions(for paneID: PaneID) -> EditorSessions? { sessions[paneID] }

    /// Each chat pane's conversation, held here for the same reason the editor's tabs are:
    /// an answer that is still streaming must outlive the view showing it.
    private var chats: [PaneID: ChatStore] = [:]

    /// This pane's chat, or nil for a pane that is not one.
    public func chatStore(for paneID: PaneID) -> ChatStore? { chats[paneID] }

    /// Which panes are editors, so the app can find one to send a file to.
    public func editorPanes() -> Set<PaneID> { Set(sessions.keys) }

    /// A pane's description changed without the pane needing to be rebuilt — an editor
    /// switched tabs, so its header should name the file it is now showing. Distinct from
    /// `onRootChange`, which asks for a REBUILD because the tile is looking somewhere else
    /// entirely.
    public var onRecordChange: ((PaneID, PaneRecord) -> Void)?

    /// Kinds this factory can build. Everything else belongs to the shell factory.
    public static let supported: Set<PaneRecord.Kind> = [.fileTree, .editor, .todo, .ports, .resources, .git, .context, .chat]

    public func makeContent(for paneID: PaneID) -> (view: NSView, record: PaneRecord)? {
        let kind = pendingKind ?? records[paneID]?.kind
        guard let kind, Self.supported.contains(kind) else { return nil }
        pendingKind = nil

        // A restored — or retargeted — tile reopens on its own directory; a new one follows
        // the work. See `TileContext.currentDirectory`.
        let root = records[paneID]?.cwd.map { URL(fileURLWithPath: $0) }
            ?? context.currentDirectory()
        var paneContext = context
        paneContext.root = root
        paneContext.setRoot = { [weak self] url in self?.retarget(paneID, to: url) }

        let view: NSView
        switch kind {
        case .fileTree:
            view = NSHostingView(rootView: FileTreeTile(context: paneContext))
        case .editor:
            // The sessions outlive the view: a pane rebuilt for any reason keeps what is open.
            let open = sessions[paneID] ?? EditorSessions()
            sessions[paneID] = open
            open.onSelectionChange = { [weak self] path in
                self?.noteEditorSelection(paneID, path: path, root: root)
            }
            // A staged request wins; a restored pane reopens whatever it had.
            if let pendingRequest {
                open.open(pendingRequest)
            } else if open.isEmpty,
                      let file = records[paneID]?.command.map({ URL(fileURLWithPath: $0) }) {
                open.open(.file(file))
            }
            pendingRequest = nil
            view = NSHostingView(rootView: EditorTile(context: paneContext, sessions: open))
            if let path = open.selected?.path {
                let record = Self.record(for: kind, root: root,
                                         file: URL(fileURLWithPath: path))
                records[paneID] = record
                hosts[paneID] = view
                return (view, record)
            }
        case .todo:
            view = NSHostingView(rootView: TodoTile(context: paneContext))
        case .ports:
            view = NSHostingView(rootView: PortsTile(context: paneContext))
        case .resources:
            view = NSHostingView(rootView: ResourcesTile(context: paneContext))
        case .git:
            view = NSHostingView(rootView: GitTile(context: paneContext))
        case .context:
            view = NSHostingView(rootView: ContextTile(context: paneContext))
        case .chat:
            // The PROJECT's root, not the shell's folder: a chat is about the project, and
            // its transcripts live beside the project's todo and context files.
            let projectRoot = context.projectRoot
            let store = chats[paneID] ?? ChatStore(
                root: projectRoot,
                conversationID: records[paneID]?.command.flatMap(UUID.init(uuidString:)))
            chats[paneID] = store
            store.onChange = { [weak self] conversation in
                self?.noteChat(paneID, conversation, root: projectRoot)
            }
            view = NSHostingView(rootView: ChatTile(context: paneContext, store: store))
            view.setAccessibilityLabel("Chat")
            hosts[paneID] = view
            let record = Self.chatRecord(for: store.current, root: projectRoot)
            records[paneID] = record
            return (view, record)
        default:
            return nil
        }
        view.setAccessibilityLabel(Self.title(for: kind, root: root))
        hosts[paneID] = view
        let record = Self.record(for: kind, root: root)
        records[paneID] = record
        return (view, record)
    }

    public func release(_ paneID: PaneID) {
        hosts.removeValue(forKey: paneID)
        sessions.removeValue(forKey: paneID)
        chats.removeValue(forKey: paneID)?.stop()
    }

    /// Keep a chat pane's header on the model it is talking to, and its record on the
    /// conversation it is showing, so a restored workspace reopens the same thread.
    private func noteChat(_ paneID: PaneID, _ conversation: ChatConversation, root: URL) {
        let record = Self.chatRecord(for: conversation, root: root)
        records[paneID] = record
        onRecordChange?(paneID, record)
    }

    /// `command` carries the conversation id, the way it carries an editor's open file.
    static func chatRecord(for conversation: ChatConversation, root: URL) -> PaneRecord {
        PaneRecord(kind: .chat, title: "Chat", subtitle: conversation.model,
                   icon: icon(for: .chat), cwd: root.path,
                   command: conversation.messages.isEmpty ? nil : conversation.id.uuidString)
    }

    /// Keep a pane's header on the tab that is showing.
    ///
    /// Only the SELECTED tab is persisted. A diff is a view of state that moves — restoring
    /// one would mean reopening a diff of changes that may since have been committed — and
    /// the record has one `command` field, not a list. What comes back is the file you were
    /// last looking at, which is the tab you would have reopened first anyway.
    private func noteEditorSelection(_ paneID: PaneID, path: String?, root: URL) {
        let file = path.map { URL(fileURLWithPath: $0) }
        let isDiff = sessions[paneID]?.selected?.isDiff ?? false
        var record = Self.record(for: .editor, root: root, file: isDiff ? nil : file)
        if isDiff, let file {
            // Named for what it is, so a header does not claim a diff is an open document.
            record.title = file.lastPathComponent
            record.subtitle = "diff"
        }
        records[paneID] = record
        onRecordChange?(paneID, record)
    }

    /// Which folder a tile is pointed at, or nil for a pane this factory does not own.
    public func root(of paneID: PaneID) -> URL? {
        records[paneID]?.cwd.map { URL(fileURLWithPath: $0) }
    }

    /// Tiles that mean something different when pointed somewhere else.
    ///
    /// Ports and Resources attribute by process ancestry rather than by path, and Todo and
    /// Context keep their own "where is this list stored" control — for those, a folder
    /// control would be a second, disagreeing answer to the same question.
    public static let folderScoped: Set<PaneRecord.Kind> = [.fileTree, .git]

    public func canRetarget(_ paneID: PaneID) -> Bool {
        records[paneID].map { Self.folderScoped.contains($0.kind) } ?? false
    }

    /// Point an existing tile at a different folder.
    ///
    /// Records the new root and asks to be rebuilt on it. Rebuilding rather than mutating
    /// the tile in place is deliberate: a Git tile aimed at another repository shares
    /// nothing with the one it was showing — not its branch, not its diffs, not its
    /// expanded folders — and a tile that kept half of the old state would be showing two
    /// repositories at once.
    public func retarget(_ paneID: PaneID, to url: URL) {
        guard var record = records[paneID], Self.folderScoped.contains(record.kind) else { return }
        let root = url.standardizedFileURL
        guard record.cwd != root.path else { return }
        record.cwd = root.path
        record.title = Self.title(for: record.kind, root: root)
        record.subtitle = Self.subtitle(for: record.kind, root: root)
        records[paneID] = record
        onRootChange?(paneID, record)
    }

    /// Forget everything remembered about a pane, including what kind it was RESTORED as.
    /// Without this, converting a restored tile into a shell would see the old kind on the
    /// next build and quietly rebuild the tile instead.
    public func forget(_ paneID: PaneID) {
        hosts.removeValue(forKey: paneID)
        records.removeValue(forKey: paneID)
        sessions.removeValue(forKey: paneID)
        chats.removeValue(forKey: paneID)?.stop()
    }

    public static func record(for kind: PaneRecord.Kind,
                              root: URL,
                              file: URL? = nil) -> PaneRecord {
        PaneRecord(kind: kind,
                   title: file?.lastPathComponent ?? title(for: kind, root: root),
                   subtitle: file == nil ? subtitle(for: kind, root: root) : nil,
                   icon: icon(for: kind),
                   cwd: root.path,
                   // `command` carries the open file for an editor pane, so a restored
                   // workspace reopens what was being edited.
                   command: file?.path)
    }

    /// A tile's header carries the same thing a shell's does — where it is pointed.
    public static func title(for kind: PaneRecord.Kind, root: URL) -> String {
        switch kind {
        case .todo: "Todo"
        case .ports: "Ports"
        case .resources: "Resources"
        case .git: "Git"
        case .editor: "Editor"
        case .context: "Context"
        case .chat: "Chat"
        default: abbreviate(root.path)
        }
    }

    /// The second line of a tile's header: WHERE it is pointed, when its title does not
    /// already say. A Git tile can be aimed at a repository other than the project's, and a
    /// header reading only "Git" would leave the user to guess which one they are staging in.
    public static func subtitle(for kind: PaneRecord.Kind, root: URL) -> String? {
        switch kind {
        case .git: root.lastPathComponent
        // A file tree's title is already its path; repeating it would be two lines saying
        // the same thing.
        default: nil
        }
    }

    public static func icon(for kind: PaneRecord.Kind) -> String {
        switch kind {
        case .fileTree: "folder"
        case .editor: "doc.text"
        case .todo: "checklist"
        case .ports: "network"
        case .resources: "gauge.with.dots.needle.33percent"
        case .git: "arrow.trianglehead.branch"
        case .context: "paperclip"
        case .chat: "text.bubble"
        case .shell, .placeholder: "apple.terminal"
        }
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
