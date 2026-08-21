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

    public init(root: URL,
                injectIntoShell: @escaping (String) -> Void = { _ in },
                revealInFinder: @escaping (URL) -> Void = { _ in }) {
        self.root = root
        self.injectIntoShell = injectIntoShell
        self.revealInFinder = revealInFinder
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
