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
    /// Whether the progress bar floats over the foot of the list. Per project and
    /// remembered, like the list's location: closing it on the bar's own control is a
    /// choice about this list, and the footer's toggle brings it back.
    public private(set) var showsProgress: Bool
    /// The sections folded down to their heading, by TITLE — the same handle the composer's
    /// target uses, for the same reason: every edit renumbers the lines. Per project and
    /// remembered, like the progress bar: a section folded away is meant to stay out of the way.
    public private(set) var collapsedSections: Set<String>

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
        self.showsProgress = UserDefaults.standard.object(forKey: Self.progressKey(for: root)) as? Bool ?? true
        self.collapsedSections = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey(for: root)) ?? [])
        load()
        beginWatching()
    }

    public func toggleProgress() { setShowsProgress(!showsProgress) }

    public func setShowsProgress(_ shows: Bool) {
        showsProgress = shows
        UserDefaults.standard.set(shows, forKey: Self.progressKey(for: root))
    }

    static func progressKey(for root: URL) -> String {
        "ultra.todoProgress." + root.standardizedFileURL.path
    }

    // MARK: Collapsing

    public func isCollapsed(_ section: String) -> Bool { collapsedSections.contains(section) }

    public func toggleCollapsed(_ section: String) {
        setCollapsed(!isCollapsed(section), for: section)
    }

    public func setCollapsed(_ collapsed: Bool, for section: String) {
        var sections = collapsedSections
        if collapsed { sections.insert(section) } else { sections.remove(section) }
        setCollapsedSections(sections)
    }

    /// Every section the file has, folded. Only ones that exist, so the set never names a
    /// heading that is not there.
    public func collapseAll() { setCollapsedSections(Set(document.sections)) }
    public func expandAll() { setCollapsedSections([]) }

    /// Whether Collapse All would fold anything.
    public var canCollapseAll: Bool { document.sections.contains { !isCollapsed($0) } }
    /// Whether Expand All would open anything.
    public var canExpandAll: Bool { document.sections.contains { isCollapsed($0) } }

    private func setCollapsedSections(_ sections: Set<String>) {
        guard sections != collapsedSections else { return }
        collapsedSections = sections
        let key = Self.collapsedKey(for: root)
        if sections.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(sections.sorted(), forKey: key)
        }
    }

    static func collapsedKey(for root: URL) -> String {
        "ultra.todoCollapsed." + root.standardizedFileURL.path
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

    /// The file a Todo pane on this project would open: the remembered choice, or the
    /// default. What `AGENTS.md` names, so the two agree.
    public static func currentLocation(for root: URL) -> URL {
        storedLocation(for: root) ?? preferredLocation(in: root)
    }

    static func defaultsKey(for root: URL) -> String {
        "ultra.todoLocation." + root.standardizedFileURL.path
    }

    /// Where the user has pointed this project's list, if they have.
    public static func storedLocation(for root: URL) -> URL? {
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
    /// Every ticked task, gone. Nothing to remove is a no-op that does not touch the file.
    public func removeCompleted() {
        guard document.completedCount > 0 else { return }
        edit { $0.removeCompleted() }
    }
    public func move(_ id: Int, before target: Int) { edit { $0.move(id, before: target) } }

    public func addItem(_ text: String, to section: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.addItem(trimmed, to: section) }
    }

    /// Add at the head of the list. Same emptiness guard as `addItem` — a return pressed on
    /// a blank field must not write a task with no text into the file.
    public func prependItem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.prependItem(trimmed) }
    }

    /// Add at the head of one section — see `TodoDocument.prependItem(_:to:)`.
    public func prependItem(_ text: String, to section: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit { $0.prependItem(trimmed, to: section) }
    }

    public func addSection(_ title: String, level: Int = 2) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        edit { $0.addSection(title, level: level) }
    }

    /// A renamed section stays folded or open as it was: the fold follows the section, not
    /// the old spelling of its name.
    public func setHeading(_ title: String, for id: Int) {
        let old = heading(id)?.title
        edit { $0.setHeading(title, for: id) }
        if let old, isCollapsed(old), let new = heading(id)?.title, new != old {
            var sections = collapsedSections
            sections.remove(old)
            sections.insert(new)
            setCollapsedSections(sections)
        }
    }

    /// A removed heading's tasks join the section above, which may be open — so the fold goes
    /// with the heading, unless another section still answers to that name.
    public func removeHeading(_ id: Int) {
        let old = heading(id)?.title
        edit { $0.removeHeading(id) }
        if let old, !document.sections.contains(old) { setCollapsed(false, for: old) }
    }

    private func heading(_ id: Int) -> TodoDocument.Heading? {
        document.grouped.lazy.compactMap(\.heading).first { $0.id == id }
    }

    /// The whole list, gone: an empty file in its place, and no folds left over.
    /// Nothing to clear is a no-op that does not touch the file.
    public func removeAll() {
        guard !document.isBlank else { return }
        edit { $0.removeAll() }
        expandAll()
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

    /// Close the notice strip. The next save or reload would clear it anyway; this is for
    /// not waiting.
    public func dismissNotice() { notice = nil }

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
