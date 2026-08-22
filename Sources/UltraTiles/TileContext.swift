import Foundation

/// What every tile is handed when it is built.
///
/// Deliberately a struct of closures rather than a reference to the app: a tile can be
/// previewed, and unit-tested, by passing an inert context. See docs/03-TILES.md.
@MainActor
public struct TileContext {
    /// The project root this pane belongs to.
    public var root: URL
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
    /// Open a file in a new editor pane. The file tree's reason to exist beyond `ls`.
    public var openInEditor: (URL) -> Void

    public init(root: URL,
                injectIntoShell: @escaping (String) -> Void = { _ in },
                revealInFinder: @escaping (URL) -> Void = { _ in },
                shellPIDs: @escaping () -> Set<Int32> = { [] },
                currentDirectory: (() -> URL)? = nil,
                openInEditor: @escaping (URL) -> Void = { _ in }) {
        self.root = root
        self.injectIntoShell = injectIntoShell
        self.revealInFinder = revealInFinder
        self.shellPIDs = shellPIDs
        self.currentDirectory = currentDirectory ?? { root }
        self.openInEditor = openInEditor
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
