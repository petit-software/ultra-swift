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

    public func loadAll() -> [WorkspaceDocument] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))
            ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .compactMap { load($0) }
    }

    private func quarantine(_ source: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = source.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: source, to: target)
    }
}
