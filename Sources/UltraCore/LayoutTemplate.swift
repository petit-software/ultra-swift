import Foundation
import UltraLayout

/// One project's arrangement of panes, made fit for another project.
///
/// "Apply this layout to all projects" is what this is for. The arrangement is the TREE —
/// which kinds, where, at what sizes — and the tree is the part worth copying. Everything
/// that ties a pane to the project it was made in is not: its id, the folder it points at,
/// the file it has open, the history it would try to restore. A copy that carried those
/// across would be a Git pane in project B still watching project A's checkout.
extension WorkspaceDocument {

    /// This document, holding `source`'s panes in place of its own.
    ///
    /// Identity, directory, title and window frame stay this document's; the tree and the
    /// pane records are `source`'s, rewritten so they belong here:
    ///
    /// - Every pane gets a FRESH id. Two workspaces sharing pane ids would share scrollback
    ///   files, and a pane released in one would be looked up by id in the other.
    /// - A pane pointed inside the source project is pointed at this project's root. One
    ///   pointed elsewhere — a todo list kept in a notes folder — keeps that folder, which
    ///   is what "elsewhere" meant in the first place.
    /// - An editor forgets its file: the file lives in the source project. The kind and the
    ///   position survive, which is the arrangement being copied.
    /// - Per-tile state is dropped for the same reason. It is the tile's own blob and it
    ///   describes the tile as it stood in the project it came from.
    /// With `keepingPanes`, the panes this document already has are not thrown away: each
    /// fills the first slot of its own kind in the new arrangement, in reading order,
    /// keeping its id — and so, for a live session, its surface and its process. Slots no
    /// pane fills are opened fresh; panes no slot fits are kept, split in after the last
    /// pane, since a layout is an arrangement and not a reason to stop a shell. Shell and
    /// agent are one kind here: an agent typed at a shell is the same pane either way.
    /// Focus stays on the pane that had it, when it survived.
    public func adoptingLayout(of source: WorkspaceDocument,
                               keepingPanes: Bool = false) -> WorkspaceDocument {
        let adopted = adoptingLayout(of: source)
        guard keepingPanes else { return adopted }

        let family = { (kind: PaneRecord.Kind) -> String in
            kind == .shell || kind == .agent ? "shell" : kind.rawValue
        }
        var unused = tree.paneIDs.filter { record(for: $0) != nil }
        var takes: [PaneID: PaneID] = [:]
        for slot in adopted.tree.paneIDs {
            guard let kind = adopted.record(for: slot)?.kind,
                  let index = unused.firstIndex(where: { family(record(for: $0)!.kind) == family(kind) })
            else { continue }
            takes[slot] = unused.remove(at: index)
        }
        let renamed = { (id: PaneID) in takes[id] ?? id }
        var tree = LayoutTree(root: Self.remap(adopted.tree.root, renamed),
                              focused: renamed(adopted.tree.focused),
                              zoomed: adopted.tree.zoomed.map(renamed))
        var out = adopted
        for (slot, existing) in takes {
            out.panes[slot.uuidString] = nil
            if let record = record(for: existing) { out.setRecord(record, for: existing) }
        }
        for leftover in unused {
            guard let last = tree.paneIDs.last else { continue }
            tree.split(last, edge: .right, newPane: leftover)
            if let record = record(for: leftover) { out.setRecord(record, for: leftover) }
        }
        if tree.contains(self.tree.focused) { tree.focused = self.tree.focused }
        out.tree = tree
        out.reconcile()
        return out
    }

    /// This document, holding `source`'s panes in place of its own — every one of them
    /// fresh. See `adoptingLayout(of:keepingPanes:)` for the version that keeps what
    /// this document already has.
    private func adoptingLayout(of source: WorkspaceDocument) -> WorkspaceDocument {
        var ids: [PaneID: PaneID] = [:]
        for paneID in source.tree.paneIDs { ids[paneID] = PaneID() }
        let fresh = { (id: PaneID) in ids[id] ?? id }

        var panes: [PaneID: PaneRecord] = [:]
        for (key, record) in source.panes {
            guard let old = PaneID(uuidString: key), let new = ids[old] else { continue }
            panes[new] = Self.retarget(record, from: source.directory, to: directory)
        }

        let tree = LayoutTree(root: Self.remap(source.tree.root, fresh),
                              focused: fresh(source.tree.focused),
                              zoomed: source.tree.zoomed.map(fresh))

        var adopted = WorkspaceDocument(id: id, directory: directory, title: title,
                                        subtitle: subtitle, tree: tree, panes: panes,
                                        windowFrame: windowFrame?.rect, themeID: themeID)
        adopted.reconcile()
        return adopted
    }

    /// The same shape with every pane and node id replaced. Node ids are regenerated by
    /// the initialisers; pane ids and `spaceFrom` go through the one map so a leaf that
    /// took its space from a sibling still names that sibling.
    private static func remap(_ node: LayoutNode, _ fresh: (PaneID) -> PaneID) -> LayoutNode {
        switch node {
        case .leaf(let leaf):
            .leaf(Leaf(paneID: fresh(leaf.paneID), spaceFrom: leaf.spaceFrom.map(fresh)))
        case .container(let container):
            .container(Container(axis: container.axis,
                                 children: container.children.map { remap($0, fresh) },
                                 fractions: container.fractions))
        }
    }

    /// One record, re-homed. See `adoptingLayout(of:)` for the rules.
    static func retarget(_ record: PaneRecord, from source: String?, to target: String?)
        -> PaneRecord {
        var out = record
        out.tileState = nil
        if record.kind == .editor { out.command = nil }
        if let cwd = record.cwd, let source, let target, isInside(cwd, source) {
            out.cwd = target
            // The title and subtitle of a shell are its path, and of a folder-scoped tile
            // its folder name. Both are rebuilt the moment the pane exists; until then the
            // header must not claim the other project's name.
            if record.kind == .shell {
                out.title = record.command ?? abbreviate(target)
                out.subtitle = record.command == nil ? nil : abbreviate(target)
            } else if record.subtitle != nil {
                out.subtitle = URL(fileURLWithPath: target).lastPathComponent
            }
        }
        return out
    }

    /// Whether `path` is `root` or somewhere under it, compared the way projects are.
    static func isInside(_ path: String, _ root: String) -> Bool {
        let path = canonical(path)
        let root = canonical(root)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
