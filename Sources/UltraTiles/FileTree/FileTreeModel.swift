import Foundation

/// The file tree's state: which directories are loaded, which are open.
///
/// Children are read lazily, one directory at a time, and cached. A project root with a
/// 40,000-file `node_modules` must cost nothing until someone actually opens it.
///
/// The view renders a FLAT array of rows rather than a recursive `OutlineGroup`. Flattening
/// keeps the row count honest — the list only ever holds what is actually visible — and it
/// makes the expand/collapse behaviour testable without a view.
@MainActor
@Observable
public final class FileTreeModel {

    public struct Node: Identifiable, Hashable, Sendable {
        public let url: URL
        public let isDirectory: Bool
        public var id: URL { url }
        public var name: String { url.lastPathComponent }
    }

    /// A visible line: a node plus how deep it sits.
    public struct Row: Identifiable, Hashable, Sendable {
        public let node: Node
        public let depth: Int
        public var id: URL { node.url }
    }

    public let root: URL
    public private(set) var children: [URL: [Node]] = [:]
    public private(set) var expanded: Set<URL> = []
    /// Directories that could not be read — permission denied, or deleted under us.
    public private(set) var unreadable: Set<URL> = []

    /// Dotfiles are shown by DEFAULT.
    ///
    /// This tree exists next to a shell in a developer's project, where the interesting
    /// files are `.env`, `.gitignore`, `.github/`, `.ultra/`. Finder hides them because its
    /// audience is not looking at repositories; hiding them here would mean the tree
    /// disagrees with `ls -a` in the pane beside it.
    public var showsHidden: Bool = true {
        didSet { guard showsHidden != oldValue else { return }; reload() }
    }

    public init(root: URL, showsHidden: Bool = true) {
        self.root = root
        self.showsHidden = showsHidden
        load(root)
    }

    // MARK: Reading

    /// Read one directory. Cheap, cached, and never recursive.
    public func load(_ url: URL) {
        guard children[url] == nil else { return }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: showsHidden ? [] : [.skipsHiddenFiles])
            children[url] = contents
                .map { entry in
                    let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory ?? false
                    return Node(url: entry, isDirectory: isDirectory)
                }
                // Directories first, then case-insensitive name. Reading order, not the
                // filesystem's arbitrary order.
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            unreadable.remove(url)
        } catch {
            children[url] = []
            unreadable.insert(url)
        }
    }

    /// Drop every cached listing and re-read what is open. Used by the refresh action and
    /// whenever `showsHidden` changes.
    public func reload() {
        let open = expanded
        children.removeAll()
        unreadable.removeAll()
        load(root)
        // Re-read only what is actually on screen, deepest last so parents exist first.
        for url in open.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            load(url)
        }
        // An expanded directory that has since vanished must not keep a stale disclosure.
        expanded = open.filter { children[$0] != nil }
    }

    // MARK: Expansion

    public func isExpanded(_ node: Node) -> Bool { expanded.contains(node.url) }

    public func toggle(_ node: Node) {
        guard node.isDirectory else { return }
        if expanded.contains(node.url) {
            collapse(node)
        } else {
            expand(node)
        }
    }

    public func expand(_ node: Node) {
        guard node.isDirectory else { return }
        load(node.url)
        expanded.insert(node.url)
    }

    /// Collapsing forgets the descendants' open state too, so reopening a folder does not
    /// explode back to a tree the user closed a minute ago.
    public func collapse(_ node: Node) {
        expanded = expanded.filter { $0 == node.url ? false : !isDescendant($0, of: node.url) }
        expanded.remove(node.url)
    }

    private func isDescendant(_ url: URL, of ancestor: URL) -> Bool {
        url.path.hasPrefix(ancestor.path + "/")
    }

    // MARK: Rendering

    /// Every visible row, in display order. Recomputed from the cache, never stored.
    public var rows: [Row] {
        var out: [Row] = []
        appendRows(of: root, depth: 0, into: &out)
        return out
    }

    private func appendRows(of directory: URL, depth: Int, into out: inout [Row]) {
        for node in children[directory] ?? [] {
            out.append(Row(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.url) {
                appendRows(of: node.url, depth: depth + 1, into: &out)
            }
        }
    }

    /// Path shown to the user: relative to the root, because a tile 200pt wide has no room
    /// for `/Users/someone/Developer/…` and the root is already in the header.
    public func displayPath(_ url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
            ? String(url.path.dropFirst(rootPath.count))
            : url.path
    }
}
