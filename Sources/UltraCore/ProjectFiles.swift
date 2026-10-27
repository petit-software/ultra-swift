import Foundation

/// A project's files by relative path, for the `@` picker at an agent's prompt.
///
/// A bounded walk rather than the file tree's lazy one: the picker filters by name across
/// the whole project at once, which is what "type three letters of the file" needs, and
/// a tree that expands a folder at a time cannot answer it. Bounded because a checkout
/// can hold a `node_modules` or a `.build` with a hundred thousand files in it, none of
/// which anyone will mention in a prompt — those folders are skipped by name, and the
/// walk stops at a cap so an unexpected one cannot stall the pane.
///
/// Pure and headless: a root in, paths out, off the main actor.
public enum ProjectFiles {

    /// Folders that hold nothing a prompt would name.
    public static let skippedFolders: Set<String> = [
        "node_modules", ".build", ".git", "DerivedData", "Pods", ".svn", ".hg",
        "dist", "build", "target", ".next", ".venv", "venv", "__pycache__", ".cache",
    ]

    /// Relative paths, folders with a trailing `/`, in the walk's order — shallow first,
    /// since the files at the top of a project are the ones most prompts are about. At
    /// most `cap` entries.
    public nonisolated static func list(in root: URL, cap: Int = 5000,
                                        showsHidden: Bool = false) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        var result: [String] = []
        var queue: [(URL, String)] = [(root.standardizedFileURL, "")]
        var index = 0
        while index < queue.count, result.count < cap {
            let (folder, prefix) = queue[index]
            index += 1
            guard let children = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys,
                options: showsHidden ? [] : [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard result.count < cap else { break }
                let name = child.lastPathComponent
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    guard !skippedFolders.contains(name) else { continue }
                    result.append(prefix + name + "/")
                    queue.append((child, prefix + name + "/"))
                } else {
                    result.append(prefix + name)
                }
            }
        }
        return result
    }
}
