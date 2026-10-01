import Foundation

/// Files and folders gathered for an agent to work on.
///
/// Stored as BOOKMARKS, not paths. The acceptance criterion is that a folder dropped from
/// Finder still resolves after the app is quit and relaunched — a recorded path stops
/// resolving the moment the user renames a parent directory, and that is the common case,
/// not the exotic one. See docs/03-TILES.md § 6.
@MainActor
@Observable
public final class ContextModel {

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var url: URL
        public var isPinned: Bool
        /// Rough token cost. Never presented as exact — it is a budgeting aid, not a bill.
        public var tokens: Int
        public var isDirectory: Bool
        public var isMissing: Bool = false
        /// On-disk size; a folder's is the sum of its files, up to the walk's cap.
        public var bytes: Int = 0
        /// How many files a folder holds, up to the cap. Nil for a file.
        public var fileCount: Int? = nil
        public var name: String { url.lastPathComponent }

        /// What the card calls the item's type: the extension in capitals — `MD`, `SWIFT` —
        /// or `Folder`, and `File` for a file with no extension, so the slot is never blank.
        public var kind: String {
            if isDirectory { return "Folder" }
            let ext = url.pathExtension
            return ext.isEmpty ? "File" : ext.uppercased()
        }

        /// `3.9 KB`, in the units Finder uses, so the number here agrees with the one in
        /// Get Info.
        public var sizeText: String { Self.sizeText(bytes) }

        /// The caption under the name: kind, then the measurements that apply, each separated
        /// by a middle dot. A folder adds its file count. The tokens are `~114k`, the same
        /// compact spelling as the footer's total, which is where the word "tokens" and the
        /// tilde's explanation live — on a narrow tile a folder's caption has no room for
        /// the word, and a count clipped to `~114k to…` reads as a different number. A
        /// missing item says only that — its size and tokens are stale facts about a file
        /// that is not there.
        public var caption: String {
            if isMissing { return "missing" }
            var parts = [kind]
            if let fileCount { parts.append(fileCount == 1 ? "1 file" : "\(fileCount) files") }
            parts.append(sizeText)
            parts.append("~" + Self.compact(tokens))
            return parts.joined(separator: " · ")
        }

        static func sizeText(_ bytes: Int) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }

        static func compact(_ value: Int) -> String {
            guard value >= 1000 else { return String(value) }
            let thousands = Double(value) / 1000
            return thousands >= 100
                ? String(format: "%.0fk", thousands)
                : String(format: "%.1fk", thousands).replacingOccurrences(of: ".0k", with: "k")
        }
    }

    /// What actually goes to disk.
    struct Stored: Codable {
        var id: UUID
        var bookmark: Data?
        /// Kept alongside the bookmark purely so a broken bookmark can still show the user
        /// WHICH file went missing rather than a blank row.
        var path: String
        var isPinned: Bool
    }

    public private(set) var items: [Item] = []
    public var totalTokens: Int { items.reduce(0) { $0 + $1.tokens } }

    private var bookmarks: [UUID: Data] = [:]
    public private(set) var storeURL: URL
    private let root: URL

    public init(root: URL) {
        self.root = root
        storeURL = Self.storedLocation(for: root) ?? Self.defaultLocation(in: root)
        load()
    }

    public static func defaultLocation(in root: URL) -> URL {
        root.appendingPathComponent(".ultra/context.json")
    }

    /// Point this list at a different file, and remember it. Like the todo list, a context
    /// list belongs to a project, so the project decides where it lives.
    public func relocate(to newURL: URL) {
        UserDefaults.standard.set(newURL.path, forKey: Self.defaultsKey(for: root))
        storeURL = newURL
        items.removeAll()
        bookmarks.removeAll()
        load()
    }

    public func resetLocation() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: root))
        storeURL = Self.defaultLocation(in: root)
        items.removeAll()
        bookmarks.removeAll()
        load()
    }

    static func defaultsKey(for root: URL) -> String {
        "ultra.contextLocation." + root.standardizedFileURL.path
    }

    static func storedLocation(for root: URL) -> URL? {
        (UserDefaults.standard.string(forKey: defaultsKey(for: root))).map {
            URL(fileURLWithPath: $0)
        }
    }

    // MARK: Mutation

    @discardableResult
    public func add(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard !items.contains(where: { $0.url.standardizedFileURL == standardized }) else {
            return false
        }
        let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory ?? false
        let id = UUID()
        bookmarks[id] = try? standardized.bookmarkData(options: [],
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)
        let measure = Self.measure(at: standardized, isDirectory: isDirectory)
        items.append(Item(id: id,
                          url: standardized,
                          isPinned: false,
                          tokens: measure.tokens,
                          isDirectory: isDirectory,
                          bytes: measure.bytes,
                          fileCount: measure.fileCount))
        sort()
        save()
        return true
    }

    public func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        bookmarks[item.id] = nil
        save()
    }

    public func togglePin(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        sort()
        save()
    }

    public func removeAllUnpinned() {
        for item in items where !item.isPinned { bookmarks[item.id] = nil }
        items.removeAll { !$0.isPinned }
        save()
    }

    /// Pinned first, then by name. Pinning is the user saying "this one stays across the
    /// churn", so it has to be visible as an ordering, not just a badge.
    private func sort() {
        items.sort {
            $0.isPinned != $1.isPinned
                ? $0.isPinned
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: Reference text

    /// `@path` references, the form the agent CLIs already understand.
    public func referenceText(relativeTo root: URL) -> String {
        items.map { Self.reference(for: $0, relativeTo: root) }.joined(separator: " ")
    }

    /// ONE item's reference, in exactly the form the whole-list send uses.
    ///
    /// Sending the list is the tile's headline verb, but a context list is gathered over a
    /// session and most prompts want one file out of it — without this the only route was to
    /// send everything and delete back the references you did not mean.
    public static func reference(for item: Item, relativeTo root: URL) -> String {
        "@" + relativePath(item.url, to: root)
    }

    static func relativePath(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Measurement

    /// What one walk of an item learns: its size, how many files it holds, and the token
    /// estimate derived from the size.
    struct Measure: Equatable {
        var bytes: Int
        /// Nil for a file; a folder's count stops at the walk's cap.
        var fileCount: Int?
        /// Bytes ÷ 4 — the usual rule of thumb for English source text.
        var tokens: Int { bytes / 4 }
    }

    /// A file is measured directly. A directory is summed over its files, capped, because
    /// walking a huge tree to produce a number nobody will act on precisely is not worth the
    /// stall — and the same walk counts the files, so the card can say `312 files` without
    /// a second one.
    static func measure(at url: URL, isDirectory: Bool, fileCap: Int = 400) -> Measure {
        guard isDirectory else {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Measure(bytes: size, fileCount: nil)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return Measure(bytes: 0, fileCount: 0) }
        var total = 0
        var seen = 0
        for case let child as URL in enumerator {
            guard seen < fileCap else { break }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            seen += 1
            total += values?.fileSize ?? 0
        }
        return Measure(bytes: total, fileCount: seen)
    }

    /// The token half of `measure`, for callers that want only the number.
    static func estimateTokens(at url: URL, isDirectory: Bool, fileCap: Int = 400) -> Int {
        measure(at: url, isDirectory: isDirectory, fileCap: fileCap).tokens
    }

    // MARK: Persistence

    func save() {
        let stored = items.map {
            Stored(id: $0.id, bookmark: bookmarks[$0.id], path: $0.url.path, isPinned: $0.isPinned)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        items = stored.map { entry in
            var isStale = false
            let resolved = entry.bookmark.flatMap {
                try? URL(resolvingBookmarkData: $0, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &isStale)
            }
            // Falling back to the recorded path keeps the row visible and named even when
            // the file is genuinely gone — a silently shorter list is worse than a marked one.
            let url = resolved ?? URL(fileURLWithPath: entry.path)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            bookmarks[entry.id] = entry.bookmark
            let measure = exists
                ? Self.measure(at: url, isDirectory: isDirectory)
                : Measure(bytes: 0, fileCount: nil)
            return Item(id: entry.id,
                        url: url,
                        isPinned: entry.isPinned,
                        tokens: measure.tokens,
                        isDirectory: isDirectory,
                        isMissing: !exists,
                        bytes: measure.bytes,
                        fileCount: measure.fileCount)
        }
        sort()
        // A bookmark that resolved to a new location is re-recorded, so the next launch does
        // not have to chase the same move again.
        let recordedPaths = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.path) })
        let moved = items.contains { item in recordedPaths[item.id] != item.url.path }
        if moved { save() }
    }
}
