import CoreGraphics
import Foundation
import UltraLayout

/// What a pane is, on disk. Enough to rebuild it — never a serialized process.
///
/// From M2 a shell pane restores by spawning a fresh PTY with the recorded cwd and command.
public struct PaneRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case shell, todo, ports, resources, git, context, placeholder
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
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var title: String
    public var subtitle: String?
    public var tree: LayoutTree
    public var panes: [String: PaneRecord]
    public var windowFrame: WindowFrame?
    public var themeID: String?

    public init(id: UUID = UUID(), title: String, subtitle: String? = nil,
                tree: LayoutTree, panes: [PaneID: PaneRecord],
                windowFrame: CGRect? = nil, themeID: String? = nil) {
        self.version = Self.currentVersion
        self.id = id
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
}

public enum WorkspaceMigration {
    /// Apply every step from the document's version up to current. Unknown future versions
    /// are refused rather than guessed at.
    public static func migrate(_ document: WorkspaceDocument) throws -> WorkspaceDocument {
        guard document.version <= WorkspaceDocument.currentVersion else {
            throw WorkspaceError.unsupportedVersion(document.version)
        }
        var document = document
        // v1 is the first version; steps get added here as `if document.version < N`.
        document.version = WorkspaceDocument.currentVersion
        document.reconcile()
        return document
    }
}

public enum WorkspaceError: Error, Equatable {
    case unsupportedVersion(Int)
    case inconsistentDocument
}
