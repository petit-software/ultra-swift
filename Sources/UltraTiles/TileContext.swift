import Foundation

/// What every tile is handed when it is built.
///
/// Deliberately a struct of closures rather than a reference to the app: a tile can be
/// previewed, and unit-tested, by passing an inert context. See docs/03-TILES.md.
@MainActor
public struct TileContext {
    /// The folder THIS PANE is pointed at.
    ///
    /// Not necessarily the project's: a Git tile can be aimed at a sibling checkout and a
    /// file tree at a folder above the project, which is what `setRoot` is for.
    public var root: URL
    /// The project the workspace was opened on, whatever this pane is currently showing.
    /// The "Project Folder" a retargeted tile can be sent back to.
    public var projectRoot: URL
    /// Type text at the focused shell's prompt WITHOUT submitting it, so the user can add
    /// to it before running. The shared verb behind "send to shell" in every tile.
    public var injectIntoShell: (String) -> Void
    /// Reveal a path in Finder.
    public var revealInFinder: (URL) -> Void
    /// The pids of this workspace's shells. Ports and Resources attribute by ancestry from
    /// these, which is what separates "this project's dev server" from every other listener
    /// on the machine. Read fresh on each poll, because panes open and close.
    public var shellPIDs: () -> Set<Int32>
    /// Where a NEW tile should point.
    ///
    /// The focused shell's working directory when there is one, NOT the directory the app
    /// happened to start in. A bundled app is launched by launchd with "/" as its cwd, so
    /// the workspace root is $HOME — and a Git tile opened beside a repo would sit there
    /// truthfully reporting "not a repository", which reads as the tile being broken.
    public var currentDirectory: () -> URL
    /// Show something in an editor pane — a file, or a file's diff.
    ///
    /// ONE verb for both, and it targets an editor that already exists before it considers
    /// making another. That is what "click four changed files" has to mean: four tabs in one
    /// pane. A per-caller verb that always split a new pane off is what made the file tree
    /// and the Git tile feel like separate apps sharing a window.
    public var openInEditor: (EditorRequest) -> Void
    /// Point this pane at a different folder.
    ///
    /// The pane keeps its id, its position and its size; only what it is looking at changes.
    /// Its record follows, so the header, the tab, and the restored workspace all agree with
    /// what is on screen. A no-op for tiles that are not folder-scoped.
    public var setRoot: (URL) -> Void

    public init(root: URL,
                injectIntoShell: @escaping (String) -> Void = { _ in },
                revealInFinder: @escaping (URL) -> Void = { _ in },
                shellPIDs: @escaping () -> Set<Int32> = { [] },
                currentDirectory: (() -> URL)? = nil,
                openInEditor: @escaping (EditorRequest) -> Void = { _ in },
                setRoot: @escaping (URL) -> Void = { _ in }) {
        self.root = root
        self.projectRoot = root
        self.injectIntoShell = injectIntoShell
        self.revealInFinder = revealInFinder
        self.shellPIDs = shellPIDs
        self.currentDirectory = currentDirectory ?? { root }
        self.openInEditor = openInEditor
        self.setRoot = setRoot
    }

    /// A context that does nothing, for previews and tests.
    public static func inert(root: URL = URL(fileURLWithPath: NSHomeDirectory())) -> TileContext {
        TileContext(root: root)
    }
}

/// Quote a path for a shell prompt.
///
/// Single quotes, with embedded single quotes broken out — the one form that is safe for
/// every character a macOS filename may contain, spaces and `$` included.
public func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
