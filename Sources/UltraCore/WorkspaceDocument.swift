import CoreGraphics
import Foundation
import UltraLayout

/// What a pane is, on disk. Enough to rebuild it — never a serialized process.
///
/// From M2 a shell pane restores by spawning a fresh PTY with the recorded cwd and command.
public struct PaneRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case shell, fileTree, editor, todo, ports, resources, git, context, chat, placeholder
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var icon: String
    /// Working directory. A pane whose cwd no longer exists restores into an error state
    /// with an "open elsewhere" action — never a silent fallback to `$HOME`.
    public var cwd: String?
    public var command: String?
    /// Opaque per-tile state, decoded by the tile itself.
    public var tileState: Data?

    public init(kind: Kind, title: String, subtitle: String? = nil,
                icon: String = "apple.terminal", cwd: String? = nil,
                command: String? = nil, tileState: Data? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.cwd = cwd
        self.command = command
        self.tileState = tileState
    }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y
        width = rect.size.width; height = rect.size.height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// One workspace, as written to disk.
public struct WorkspaceDocument: Codable, Equatable, Sendable {
    /// Bumped whenever the shape changes. Migration is a pure function per version step,
    /// each with a fixture test.
    public static let currentVersion = 2

    public var version: Int
    public var id: UUID
    /// The project this workspace IS — the absolute path its panes, its agent socket, and
    /// its per-project files are all scoped to.
    ///
    /// Optional only because a v1 document predates it and the migration cannot always
    /// recover one. A document with no directory is never matched to a project; it is
    /// restorable but not findable, which is the honest outcome.
    public var directory: String?
    public var title: String
    public var subtitle: String?
    public var tree: LayoutTree
    public var panes: [String: PaneRecord]
    public var windowFrame: WindowFrame?
    public var themeID: String?

    public init(id: UUID = UUID(), directory: String? = nil,
                title: String, subtitle: String? = nil,
                tree: LayoutTree, panes: [PaneID: PaneRecord],
                windowFrame: CGRect? = nil, themeID: String? = nil) {
        self.version = Self.currentVersion
        self.id = id
        self.directory = directory.map(WorkspaceDocument.canonical)
        self.title = title
        self.subtitle = subtitle
        self.tree = tree
        self.panes = Dictionary(uniqueKeysWithValues: panes.map { ($0.key.uuidString, $0.value) })
        self.windowFrame = windowFrame.map(WindowFrame.init)
        self.themeID = themeID
    }

    public func record(for paneID: PaneID) -> PaneRecord? { panes[paneID.uuidString] }

    public mutating func setRecord(_ record: PaneRecord, for paneID: PaneID) {
        panes[paneID.uuidString] = record
    }

    /// Discard records for panes no longer in the tree, and refuse a tree whose panes have
    /// no records at all — a half-written document must not become the restored layout.
    public mutating func reconcile() {
        let live = Set(tree.paneIDs.map(\.uuidString))
        panes = panes.filter { live.contains($0.key) }
    }

    public var isConsistent: Bool {
        tree.validate().isEmpty && tree.paneIDs.allSatisfy { panes[$0.uuidString] != nil }
    }

    /// Does this document belong to `path`?
    ///
    /// Compared canonically, because the same project arrives spelled several ways: with a
    /// trailing slash from a drag, through `~` from a config, and through a symlink from
    /// `/tmp`. Three spellings of one project would be three workspaces, each with its own
    /// layout, and the user would see their panes vanish depending on how they opened it.
    public func belongs(to path: String) -> Bool {
        guard let directory else { return false }
        return directory == Self.canonical(path)
    }

    /// One spelling per project: tilde expanded, symlinks resolved, trailing slash dropped.
    public static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }
}

public enum WorkspaceMigration {
    /// Apply every step from the document's version up to current. Unknown future versions
    /// are refused rather than guessed at.
    public static func migrate(_ document: WorkspaceDocument) throws -> WorkspaceDocument {
        guard document.version <= WorkspaceDocument.currentVersion else {
            throw WorkspaceError.unsupportedVersion(document.version)
        }
        var document = document
        // v1 → v2 added `directory`. A v1 document never stored one, but its SUBTITLE was
        // written as the abbreviated path, so the tilde form can be expanded back. That is a
        // recovery, not a guarantee: a document whose subtitle was overridden by the user
        // gets no directory and simply is not matched to a project, rather than being
        // adopted by whichever project the string happens to resemble.
        if document.version < 2 {
            document.directory = document.subtitle
                .map(WorkspaceDocument.canonical)
                .flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        }
        document.version = WorkspaceDocument.currentVersion
        document.reconcile()
        return document
    }
}

public enum WorkspaceError: Error, Equatable {
    case unsupportedVersion(Int)
    case inconsistentDocument
}
