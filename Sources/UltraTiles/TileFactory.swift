import AppKit
import SwiftUI
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

    /// The file the next editor pane should open. Consumed once, like the kind.
    private var pendingFile: URL?
    public func stage(file: URL?) { pendingFile = file }

    /// Kinds this factory can build. Everything else belongs to the shell factory.
    public static let supported: Set<PaneRecord.Kind> = [.fileTree, .editor, .todo, .ports, .resources, .git, .context]

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
            // A staged file wins; a restored pane reopens whatever it had.
            let file = pendingFile ?? records[paneID]?.command.map { URL(fileURLWithPath: $0) }
            pendingFile = nil
            view = NSHostingView(rootView: EditorTile(context: paneContext, file: file))
            if let file {
                let record = Self.record(for: kind, root: root, file: file)
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
        default:
            return nil
        }
        view.setAccessibilityLabel(Self.title(for: kind, root: root))
        hosts[paneID] = view
        let record = Self.record(for: kind, root: root)
        records[paneID] = record
        return (view, record)
    }

    public func release(_ paneID: PaneID) { hosts.removeValue(forKey: paneID) }

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
        case .shell, .placeholder: "apple.terminal"
        }
    }

    public static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
