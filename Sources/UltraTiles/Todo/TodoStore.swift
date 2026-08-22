import Foundation

/// Owns one todo file: where it lives, what it says, and keeping both in step with disk.
///
/// Todos are FILES, not app state — the agent running in the next pane over has to be able
/// to read and rewrite them. So every edit writes through immediately, and every external
/// edit is picked up. See docs/03-TILES.md § 2.
@MainActor
@Observable
public final class TodoStore {

    public enum Notice: Equatable, Sendable {
        /// The file changed underneath us and was reloaded.
        case reloadedFromDisk
        /// We could not read or write it.
        case failed(String)
    }

    public private(set) var document = TodoDocument(text: "")
    public private(set) var url: URL
    public private(set) var notice: Notice?
    /// True once the file exists on disk. A tile pointed at a project with no list yet shows
    /// an empty state rather than inventing a file nobody asked for.
    public private(set) var exists: Bool = false

    /// Held in a box so the sources are torn down by the box's own nonisolated deinit —
    /// a main-actor deinit cannot touch main-actor state. Same shape as `ObserverBox`.
    private var watchers = WatchBox()
    /// What we last wrote. An external-change event whose content matches this is our own
    /// write echoing back, and must not trigger a reload.
    private var lastWrittenText: String?
    private let root: URL

    public init(root: URL) {
        self.root = root
        self.url = Self.storedLocation(for: root) ?? Self.preferredLocation(in: root)
        load()
        beginWatching()
    }

    /// Point this tile at a different file, and remember it.
    ///
    /// A todo list is a file in a project, so WHERE it lives is the user's call — one repo
    /// keeps it at `docs/TODO.md`, another in a notes folder outside the tree entirely.
    public func relocate(to newURL: URL) {
        UserDefaults.standard.set(newURL.path, forKey: Self.defaultsKey(for: root))
        url = newURL
        notice = nil
        lastWrittenText = nil
        load()
        beginWatching()
    }

    /// Back to `.ultra/todo.md`, or whatever the project already had.
    public func resetLocation() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: root))
        url = Self.preferredLocation(in: root)
        notice = nil
        lastWrittenText = nil
        load()
        beginWatching()
    }

    static func defaultsKey(for root: URL) -> String {
        "ultra.todoLocation." + root.standardizedFileURL.path
    }

    static func storedLocation(for root: URL) -> URL? {
        (UserDefaults.standard.string(forKey: defaultsKey(for: root))).map {
            URL(fileURLWithPath: $0)
        }
    }

    // MARK: Location

    /// `.ultra/todo.md`, unless the project already keeps a list somewhere obvious — in
    /// which case that one is adopted rather than starting a second, competing list.
    public static func preferredLocation(in root: URL) -> URL {
        let candidates = [
            root.appendingPathComponent(".ultra/todo.md"),
            root.appendingPathComponent("TODO.md"),
            root.appendingPathComponent("docs/TODO.md"),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return candidates[0]
    }

    // MARK: Reading and writing

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            document = TodoDocument(text: "")
            exists = FileManager.default.fileExists(atPath: url.path)
            return
        }
        document = TodoDocument(text: text)
        exists = true
    }

    /// Write the whole file. The document is byte-exact, so this is a faithful save even
    /// though only one line changed.
    private func save() {
        let text = document.text
        lastWrittenText = text
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            exists = true
            notice = nil
            // An atomic write replaces the inode, so the descriptor we were watching is now
            // pointed at a deleted file.
            beginWatching()
        } catch {
            notice = .failed(error.localizedDescription)
        }
    }

    // MARK: Editing

    public func toggle(_ id: Int) { edit { $0.toggle(id) } }
    public func setText(_ text: String, for id: Int) { edit { $0.setText(text, for: id) } }
    public func removeItem(_ id: Int) { edit { $0.removeItem(id) } }
    public func move(_ id: Int, before target: Int) { edit { $0.move(id, before: target) } }

    public func addItem(_ text: String, to section: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.addItem(trimmed, to: section) }
    }

    private func edit(_ change: (inout TodoDocument) -> Void) {
        change(&document)
        save()
    }

    // MARK: Watching

    /// Watch the file for writes, and its directory for atomic replaces.
    ///
    /// Editors do not modify files in place — they write a temp file and rename it over the
    /// original. That deletes the inode our descriptor points at, so a file-only watch goes
    /// deaf after exactly one external save. The directory watch is what survives it.
    private func beginWatching() {
        watchers = WatchBox()

        let descriptor = open(url.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .extend],
                queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.externalChange() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.sources.append(source)
        }

        let directory = url.deletingLastPathComponent()
        let directoryDescriptor = open(directory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.externalChange() }
        }
        source.setCancelHandler { close(directoryDescriptor) }
        source.resume()
        watchers.sources.append(source)
    }

    private func externalChange() {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        // Our own write echoing back.
        guard text != lastWrittenText else { return }
        guard text != document.text else { return }
        document = TodoDocument(text: text)
        exists = true
        notice = .reloadedFromDisk
        beginWatching()
    }

    /// Test seam: apply an external write and pick it up synchronously, without depending on
    /// a pumped runloop or a real filesystem event.
    public func reloadNow() { externalChange() }
}


/// Cancels its sources when it dies, from whatever context that happens to be.
private final class WatchBox: @unchecked Sendable {
    var sources: [DispatchSourceFileSystemObject] = []
    deinit { sources.forEach { $0.cancel() } }
}
