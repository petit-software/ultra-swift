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
    private var restored: [PaneID: PaneRecord]
    private var pendingKind: PaneRecord.Kind?
    private var hosts: [PaneID: NSView] = [:]

    public init(context: TileContext, restoring records: [PaneID: PaneRecord] = [:]) {
        self.context = context
        self.restored = records
    }

    /// The next pane created will be this kind. Consumed once, like `stageAgent` — a single
    /// "New File Tree" must not turn every later split into a file tree.
    public func stage(_ kind: PaneRecord.Kind?) { pendingKind = kind }

    /// Kinds this factory can build. Everything else belongs to the shell factory.
    public static let supported: Set<PaneRecord.Kind> = [.fileTree]

    public func makeContent(for paneID: PaneID) -> (view: NSView, record: PaneRecord)? {
        let kind = pendingKind ?? restored[paneID]?.kind
        guard let kind, Self.supported.contains(kind) else { return nil }
        pendingKind = nil

        // A restored tile reopens on its own directory; a new one takes the project root.
        let root = restored[paneID]?.cwd.map { URL(fileURLWithPath: $0) } ?? context.root
        var paneContext = context
        paneContext.root = root

        let view: NSView
        switch kind {
        case .fileTree:
            view = NSHostingView(rootView: FileTreeTile(context: paneContext))
        default:
            return nil
        }
        view.setAccessibilityLabel(Self.title(for: kind, root: root))
        hosts[paneID] = view
        return (view, Self.record(for: kind, root: root))
    }

    public func release(_ paneID: PaneID) { hosts.removeValue(forKey: paneID) }

    public static func record(for kind: PaneRecord.Kind, root: URL) -> PaneRecord {
        PaneRecord(kind: kind,
                   title: title(for: kind, root: root),
                   subtitle: nil,
                   icon: icon(for: kind),
                   cwd: root.path)
    }

    /// A tile's header carries the same thing a shell's does — where it is pointed.
    public static func title(for kind: PaneRecord.Kind, root: URL) -> String {
        abbreviate(root.path)
    }

    public static func icon(for kind: PaneRecord.Kind) -> String {
        switch kind {
        case .fileTree: "folder"
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
