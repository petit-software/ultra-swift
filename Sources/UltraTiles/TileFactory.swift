import AppKit
import SwiftUI
import UltraChat
import UltraCore
import UltraLayout
import UltraSimulator

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

    /// Each todo pane's list. Held here so a menu command — Clear Completed Tasks — can
    /// reach the list the pane is showing rather than open a second store on the same file
    /// and race the pane's own watcher.
    private var todos: [PaneID: TodoStore] = [:]

    /// This pane's list, or nil for a pane that is not a todo.
    public func todoStore(for paneID: PaneID) -> TodoStore? { todos[paneID] }

    /// Which panes are todo lists, so the app can find one for a command.
    public func todoPanes() -> Set<PaneID> { Set(todos.keys) }

    /// Each browser pane's pages, held here for the same reason: a pane rebuilt for any
    /// reason must not reload what it was showing.
    private var browsers: [PaneID: BrowserTabs] = [:]

    /// This pane's tabs, or nil for a pane that is not a browser.
    public func browserTabs(for paneID: PaneID) -> BrowserTabs? { browsers[paneID] }

    /// The page this pane is SHOWING — its selected tab — or nil for a pane that is not a
    /// browser. What a browser command acts on.
    public func browserSession(for paneID: PaneID) -> BrowserSession? { browsers[paneID]?.selected }

    /// Which panes are browsers, so the app can find one to send a URL to.
    public func browserPanes() -> Set<PaneID> { Set(browsers.keys) }

    /// What the next browser pane should open on. Consumed once, like the kind.
    private var pendingBrowse: URL?
    public func stage(browse url: URL?) { pendingBrowse = url }

    /// Each simulator pane's device and screen, held here for the same reason: the
    /// connection to the device's framebuffer must outlive the view showing it.
    private var simulators: [PaneID: SimulatorSession] = [:]

    /// This pane's simulator, or nil for a pane that is not one.
    public func simulatorSession(for paneID: PaneID) -> SimulatorSession? { simulators[paneID] }

    /// Which panes are simulators, so the app can find one to put a device on.
    public func simulatorPanes() -> Set<PaneID> { Set(simulators.keys) }

    /// The device the next simulator pane should open on, by UDID. Consumed once.
    private var pendingSimulator: String?
    public func stage(simulator udid: String?) { pendingSimulator = udid }

    /// Which panes are editors, so the app can find one to send a file to.
    public func editorPanes() -> Set<PaneID> { Set(sessions.keys) }

    /// A pane's description changed without the pane needing to be rebuilt — an editor
    /// switched tabs, so its header should name the file it is now showing. Distinct from
    /// `onRootChange`, which asks for a REBUILD because the tile is looking somewhere else
    /// entirely.
    public var onRecordChange: ((PaneID, PaneRecord) -> Void)?

    /// Kinds this factory can build. Everything else belongs to the shell factory.
    public static let supported: Set<PaneRecord.Kind> = [.fileTree, .editor, .todo, .ports, .resources, .git, .context, .chat, .browser, .simulator]

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
            // Deaf while the pane is being built. The record this returns already says what
            // is selected, and announcing it now would persist the layout from INSIDE the
            // surface store's build of this very pane — which materialises the pane again,
            // opens the staged request again, and for a new file (never reused) recurses
            // until the stack runs out.
            open.onSelectionChange = nil
            // A staged request wins; a restored pane reopens whatever it had.
            if let pendingRequest {
                open.open(pendingRequest)
            } else if open.isEmpty,
                      let file = records[paneID]?.command.map({ URL(fileURLWithPath: $0) }) {
                open.open(.file(file))
            }
            pendingRequest = nil
            open.onSelectionChange = { [weak self] path in
                self?.noteEditorSelection(paneID, path: path, root: root)
            }
            view = NSHostingView(rootView: EditorTile(context: paneContext, sessions: open))
            // A new file has no path to record: nothing of it exists to reopen.
            if let path = open.selected?.path, !path.isEmpty {
                let record = Self.record(for: kind, root: root,
                                         file: URL(fileURLWithPath: path))
                records[paneID] = record
                hosts[paneID] = view
                return (view, record)
            }
        case .todo:
            let store = todos[paneID] ?? TodoStore(root: root)
            todos[paneID] = store
            view = NSHostingView(rootView: TodoTile(context: paneContext, store: store))
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
                conversationID: records[paneID]?.command.flatMap(UUID.init(uuidString:)),
                isLight: records[paneID]?.appearance == .light)
            chats[paneID] = store
            store.onChange = { [weak self] conversation in
                self?.noteChat(paneID, conversation, root: projectRoot)
            }
            view = NSHostingView(rootView: ChatTile(context: paneContext, store: store))
            view.setAccessibilityLabel("Chat")
            hosts[paneID] = view
            let record = Self.chatRecord(for: store.current, isLight: store.isLight, root: projectRoot)
            records[paneID] = record
            return (view, record)
        case .browser:
            // A staged URL wins; a restored pane reopens the pages it was on.
            let tabs = browsers[paneID] ?? Self.browserTabs(restoring: records[paneID],
                                                            staged: pendingBrowse)
            pendingBrowse = nil
            browsers[paneID] = tabs
            tabs.onChange = { [weak self] in self?.noteBrowser(paneID, root: root) }
            view = BrowserHostingView(tile: BrowserTile(context: paneContext, tabs: tabs),
                                      tabs: tabs)
            view.setAccessibilityLabel("Browser")
            hosts[paneID] = view
            let record = Self.browserRecord(for: tabs, root: root)
            records[paneID] = record
            return (view, record)
        case .simulator:
            // A staged device wins; a restored pane reopens the device it was on.
            let session = simulators[paneID] ?? SimulatorSession(
                udid: pendingSimulator ?? records[paneID]?.command,
                zoom: SimulatorPaneState.decode(records[paneID]?.tileState).zoom)
            pendingSimulator = nil
            simulators[paneID] = session
            // Screenshots go beside the project's todo and chats, and their path is typed
            // at the shell's prompt, which is how the agent gets to see them.
            session.screenshotFolder = context.projectRoot.appendingPathComponent(".ultra", isDirectory: true)
            session.sendToShell = context.injectIntoShell
            session.onChange = { [weak self, weak session] device in
                self?.noteSimulator(paneID, device: device, zoom: session?.zoom ?? 1, root: root)
            }
            session.onZoomChange = { [weak self, weak session] zoom in
                self?.noteSimulator(paneID, device: session?.device, zoom: zoom, root: root)
            }
            view = SimulatorHostingView(tile: SimulatorTile(context: paneContext, session: session),
                                        session: session)
            view.setAccessibilityLabel("Simulator")
            hosts[paneID] = view
            let record = Self.simulatorRecord(device: session.device, zoom: session.zoom, root: root)
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
        browsers.removeValue(forKey: paneID)?.closeAll()
        simulators.removeValue(forKey: paneID)?.close()
        todos.removeValue(forKey: paneID)
    }

    /// Keep a simulator pane's header on its device, and its record on the device's UDID,
    /// so a restored workspace reopens on the same one.
    private func noteSimulator(_ paneID: PaneID, device: SimulatorDevice?, zoom: CGFloat, root: URL) {
        let record = Self.simulatorRecord(device: device, zoom: zoom, root: root)
        guard records[paneID] != record else { return }
        records[paneID] = record
        onRecordChange?(paneID, record)
    }

    /// `command` carries the device's UDID, the way it carries a browser's URL. The title
    /// is the device's name, falling back to "Simulator"; the subtitle is its runtime. The
    /// zoom rides in `tileState`, and only when it is not the fitted size.
    public static func simulatorRecord(device: SimulatorDevice?, zoom: CGFloat = 1, root: URL) -> PaneRecord {
        PaneRecord(kind: .simulator,
                   title: device?.name ?? "Simulator",
                   subtitle: device.map(\.runtimeName).flatMap { $0.isEmpty ? nil : $0 },
                   icon: device?.isTablet == true ? "ipad" : icon(for: .simulator),
                   cwd: root.path,
                   command: device?.udid,
                   tileState: SimulatorPaneState(zoom: zoom).encoded)
    }

    /// Keep a browser pane's header on the showing page's title and host, and its record
    /// on its pages, so a restored workspace reopens where it was.
    private func noteBrowser(_ paneID: PaneID, root: URL) {
        guard let tabs = browsers[paneID] else { return }
        let record = Self.browserRecord(for: tabs, root: root)
        guard records[paneID] != record else { return }
        records[paneID] = record
        onRecordChange?(paneID, record)
    }

    /// A browser pane's record: the page it is showing, and its other tabs.
    static func browserRecord(for tabs: BrowserTabs, root: URL) -> PaneRecord {
        browserRecord(url: tabs.selected.requestedURL, title: tabs.selected.title,
                      isDark: tabs.isDark, tabs: tabs.state, root: root)
    }

    /// The tabs a browser pane opens with. A staged URL is a new pane on that one page; a
    /// saved pane comes back with every tab it had, on the one that was showing; a record
    /// from before panes had tabs, or of a pane that never had a second, is the one page
    /// its `command` names.
    static func browserTabs(restoring record: PaneRecord?, staged: URL?) -> BrowserTabs {
        let isDark = record?.appearance == .dark
        if let staged { return BrowserTabs(urls: [staged], isDark: isDark) }
        if let state = BrowserPaneState.decode(record?.tileState) {
            return BrowserTabs(urls: state.tabs.map { $0.flatMap(URL.init(string:)) },
                               selected: state.selected, isDark: isDark)
        }
        return BrowserTabs(urls: [record?.command.flatMap(URL.init(string:))], isDark: isDark)
    }

    /// `command` carries the page's URL, the way it carries an editor's open file. The
    /// title is the page's own, falling back to "Browser"; the subtitle is where it is.
    /// Both are the SHOWING tab's; the rest of the pane's tabs ride in `tileState`, and
    /// only when there is more than one.
    ///
    /// The page's light or dark mode is the PANE's appearance: the canvas paints the whole
    /// pane — surface, header, glass — to match the page inside it, and the setting is saved
    /// with the pane like its URL.
    public static func browserRecord(url: URL?, title: String?, isDark: Bool = false,
                                     tabs: BrowserPaneState? = nil, root: URL) -> PaneRecord {
        PaneRecord(kind: .browser,
                   title: title ?? "Browser",
                   subtitle: url.map(BrowserSession.place(of:)).flatMap { $0.isEmpty ? nil : $0 },
                   icon: icon(for: .browser), cwd: root.path,
                   command: url?.absoluteString,
                   tileState: tabs?.encoded,
                   appearance: isDark ? .dark : .light)
    }

    /// Keep a chat pane's header on the model it is talking to, and its record on the
    /// conversation it is showing, so a restored workspace reopens the same thread.
    private func noteChat(_ paneID: PaneID, _ conversation: ChatConversation, root: URL) {
        let record = Self.chatRecord(for: conversation, isLight: chats[paneID]?.isLight ?? false,
                                     root: root)
        guard records[paneID] != record else { return }
        records[paneID] = record
        onRecordChange?(paneID, record)
    }

    /// `command` carries the conversation id, the way it carries an editor's open file.
    ///
    /// A chat shown light is the PANE's appearance, the way a browser's page mode is: the
    /// canvas paints the whole pane white to match, and the setting is saved with the pane.
    /// Unlike a browser, which is always pinned one way or the other, a chat that is not
    /// pinned light follows the app, so the record carries nil.
    public static func chatRecord(for conversation: ChatConversation, isLight: Bool = false,
                                  root: URL) -> PaneRecord {
        PaneRecord(kind: .chat, title: "Chat", subtitle: conversation.model,
                   icon: icon(for: .chat), cwd: root.path,
                   command: conversation.messages.isEmpty ? nil : conversation.id.uuidString,
                   appearance: isLight ? .light : nil)
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
        browsers.removeValue(forKey: paneID)?.closeAll()
        simulators.removeValue(forKey: paneID)?.close()
        todos.removeValue(forKey: paneID)
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
        case .browser: "Browser"
        case .simulator: "Simulator"
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
        case .browser: "globe"
        case .simulator: "iphone"
        case .agent: "sparkles"
        case .shell, .placeholder: "apple.terminal"
        }
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// A simulator pane's own saved state, in its record's `tileState`.
public struct SimulatorPaneState: Codable, Equatable, Sendable {
    public var zoom: CGFloat

    public init(zoom: CGFloat = 1) { self.zoom = zoom }

    /// Nil for the fitted size, so a pane that was never zoomed saves no state at all.
    public var encoded: Data? {
        abs(zoom - 1) < 0.001 ? nil : try? JSONEncoder().encode(self)
    }

    /// The state in `data`, or the fitted size when there is none or it does not read.
    public static func decode(_ data: Data?) -> SimulatorPaneState {
        data.flatMap { try? JSONDecoder().decode(SimulatorPaneState.self, from: $0) } ?? SimulatorPaneState()
    }
}
