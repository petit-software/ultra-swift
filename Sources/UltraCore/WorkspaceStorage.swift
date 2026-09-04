import Foundation
import UltraLayout

/// Reads and writes workspace documents.
///
/// Writes are atomic and debounced; a file that cannot be decoded is moved aside rather
/// than deleted, and the app opens with a default layout. Never a silent data loss, never
/// a launch failure. See docs/01-SPLIT-ENGINE.md § 8.
public final class WorkspaceStorage: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "com.ultra.workspace-storage")
    private var pending: [UUID: DispatchWorkItem] = [:]
    private let debounce: DispatchTimeInterval

    public init(directory: URL? = nil, debounce: DispatchTimeInterval = .milliseconds(500)) {
        self.directory = directory ?? Self.defaultDirectory
        self.debounce = debounce
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ultra/workspaces", isDirectory: true)
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: Write

    /// Debounced. Repeated calls within the window collapse to one write, so dragging a
    /// divider does not hammer the disk.
    public func scheduleSave(_ document: WorkspaceDocument) {
        queue.async { [weak self] in
            guard let self else { return }
            pending[document.id]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                try? self?.saveNow(document)
                self?.queue.async { self?.pending[document.id] = nil }
            }
            pending[document.id] = item
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
    }

    /// Write immediately — used on quit, where a debounce would lose the last change.
    public func saveNow(_ document: WorkspaceDocument) throws {
        var document = document
        document.reconcile()
        guard document.isConsistent else { throw WorkspaceError.inconsistentDocument }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document).write(to: url(for: document.id), options: .atomic)
    }

    /// Flush anything still waiting. Call before termination.
    public func flush() {
        queue.sync {
            for (_, item) in pending { item.perform(); item.cancel() }
            pending.removeAll()
        }
    }

    // MARK: Read

    /// Returns nil when there is nothing to restore. An undecodable file is quarantined
    /// alongside itself so the user can recover it, and nil is returned.
    public func load(_ id: UUID) -> WorkspaceDocument? {
        let source = url(for: id)
        guard let data = try? Data(contentsOf: source) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
            let migrated = try WorkspaceMigration.migrate(decoded)
            guard migrated.isConsistent else { throw WorkspaceError.inconsistentDocument }
            return migrated
        } catch {
            quarantine(source)
            return nil
        }
    }

    /// The saved workspace for a project, or nil if it has never been opened.
    ///
    /// This is what `loadAll().first` used to stand in for, and the reason every project
    /// resolved to the same layout: "the first document on disk" is not "this project's
    /// document" once there is more than one.
    public func load(directory: String) -> WorkspaceDocument? {
        loadAll().first { $0.belongs(to: directory) }
    }

    /// Every project with a saved workspace, most recently written first — the backing for
    /// a recents list. A document with no directory is skipped: it cannot be reopened by
    /// path, so offering it as a menu item would be offering something that does nothing.
    public func recentDirectories(limit: Int = 10) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return date.map { (url, $0) }
            }
            .sorted { $0.1 > $1.1 }
        var seen = Set<String>()
        var out: [String] = []
        for (url, _) in dated {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let path = load(id)?.directory, seen.insert(path).inserted else { continue }
            out.append(path)
            if out.count == limit { break }
        }
        return out
    }

    public func loadAll() -> [WorkspaceDocument] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .compactMap { load($0) }
    }

    // MARK: Default layout

    /// The arrangement a project gets the first time it is opened.
    ///
    /// One document beside the per-project ones, under a name that is not a UUID so
    /// `loadAll` and `recentDirectories` never mistake it for a project. Kept as a whole
    /// document rather than a bare tree: `adoptingLayout(of:)` needs the records and the
    /// source directory to re-home each pane, and a second format would be a second
    /// migration path.
    public var defaultLayoutURL: URL {
        directory.appendingPathComponent("default-layout.json")
    }

    public var hasDefaultLayout: Bool {
        FileManager.default.fileExists(atPath: defaultLayoutURL.path)
    }

    public func saveDefaultLayout(_ document: WorkspaceDocument) throws {
        var document = document
        document.reconcile()
        guard document.isConsistent else { throw WorkspaceError.inconsistentDocument }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(document).write(to: defaultLayoutURL, options: .atomic)
    }

    /// Nil when none has been set — or when the one on disk cannot be read, which is
    /// quarantined the way a project's document would be rather than left to fail every
    /// launch.
    public func loadDefaultLayout() -> WorkspaceDocument? {
        guard let data = try? Data(contentsOf: defaultLayoutURL) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
            let migrated = try WorkspaceMigration.migrate(decoded)
            guard migrated.isConsistent else { throw WorkspaceError.inconsistentDocument }
            return migrated
        } catch {
            quarantine(defaultLayoutURL)
            return nil
        }
    }

    public func clearDefaultLayout() {
        try? FileManager.default.removeItem(at: defaultLayoutURL)
    }

    private func quarantine(_ source: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = source.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: source, to: target)
    }
}
