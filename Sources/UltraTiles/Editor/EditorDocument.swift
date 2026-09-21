import Foundation

/// One file, open for editing.
///
/// Deliberately small. This is the editor you use to fix a typo in a config file without
/// leaving the terminal, not a replacement for the one you already have — so it opens, it
/// edits, it saves, and it tells the truth about what happened on disk. Everything beyond
/// that is a feature someone else's editor does better.
@MainActor
@Observable
public final class EditorDocument {

    public enum Notice: Equatable, Sendable {
        /// The file changed on disk and we had no unsaved edits, so it was reloaded.
        case reloadedFromDisk
        /// It changed on disk AND there are unsaved edits here. Nothing was overwritten.
        case conflict
        case failed(String)
    }

    public private(set) var url: URL?
    public private(set) var notice: Notice?
    public private(set) var isDirty = false
    /// True when the file cannot be shown as text at all.
    public private(set) var isBinary = false

    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            isDirty = (text != savedText)
            if notice == .reloadedFromDisk { notice = nil }
        }
    }

    /// What is believed to be on disk. The dirty flag is the difference between this and
    /// `text`, so undoing back to the saved state correctly clears it.
    private var savedText = ""
    private var watchers = WatchBox()

    /// What this is called until it has a file. Numbered by `EditorSessions`, so two new
    /// files in one sidebar can be told apart.
    private let untitledName: String

    public init() { untitledName = "Untitled" }
    public init(url: URL) { untitledName = "Untitled"; open(url) }
    /// A new file: a buffer with nowhere to go yet. The first save asks where.
    public init(untitled name: String) { untitledName = name; wantsInitialFocus = true }

    /// Whether the view showing this should take the keyboard — true exactly once, for a
    /// new file. Once, because its view is remade whenever its tab is reselected or its pane
    /// is rebuilt, and by then the keyboard belongs to wherever the user has taken it.
    @ObservationIgnored private var wantsInitialFocus = false
    public func claimInitialFocus() -> Bool {
        defer { wantsInitialFocus = false }
        return wantsInitialFocus
    }

    public var displayName: String { url?.lastPathComponent ?? untitledName }
    /// True until the first save gives it a file. `save()` cannot work on one of these —
    /// the caller has to ask where, and then `save(to:)`.
    public var isUntitled: Bool { url == nil }

    // MARK: Opening and saving

    public func open(_ url: URL) {
        self.url = url
        notice = nil
        isBinary = false
        guard let data = try? Data(contentsOf: url) else {
            savedText = ""; text = ""; isDirty = false
            notice = .failed("Could not read \(url.lastPathComponent)")
            return
        }
        // A NUL byte is the practical test for "this is not text". Opening a binary in a
        // text view produces garbage that looks editable, and saving it corrupts the file.
        if data.prefix(8000).contains(0) {
            isBinary = true
            savedText = ""; text = ""; isDirty = false
            beginWatching()
            return
        }
        let contents = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        savedText = contents
        text = contents
        isDirty = false
        beginWatching()
    }

    @discardableResult
    public func save() -> Bool {
        guard let url else { return false }
        return save(to: url)
    }

    /// Save somewhere else, and BE that file from then on — the first save of a new file,
    /// which is the only caller that has no `url` to fall back on.
    ///
    /// The folder is created when it is missing: the default home for a new file is the
    /// project's `.ultra/`, and a project that was opened rather than created here may not
    /// have one yet. `url` moves only once the write has landed, so a failed save leaves
    /// the document pointing where it was.
    @discardableResult
    public func save(to url: URL) -> Bool {
        guard !isBinary else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            self.url = url
            savedText = text
            isDirty = false
            notice = nil
            // An atomic write replaces the inode the watch was holding.
            beginWatching()
            return true
        } catch {
            notice = .failed(error.localizedDescription)
            return false
        }
    }

    public func revert() {
        text = savedText
        isDirty = false
        notice = nil
    }

    // MARK: External changes

    /// Watch the file and its directory — editors save by writing a temp file and renaming
    /// it over the original, which deletes the inode a file-only watch holds.
    private func beginWatching() {
        watchers = WatchBox()
        guard let url else { return }
        for target in [url, url.deletingLastPathComponent()] {
            let descriptor = Darwin.open(target.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
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
    }

    /// Test seam, and the body of the watch handler.
    public func externalChange() {
        guard let url, !isBinary,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else { return }
        guard contents != savedText else { return }   // our own write echoing back

        if isDirty {
            // Never silently discard either side. The buffer is left alone and the user is
            // told; reverting is one click and is the only thing that drops their edits.
            notice = .conflict
        } else {
            savedText = contents
            text = contents
            isDirty = false
            notice = .reloadedFromDisk
        }
    }

    public func dismissNotice() { notice = nil }
}

// MARK: - Where a new file goes

extension EditorDocument {
    /// The folder a new file is offered first: the project's `.ultra/`, beside its todo list
    /// and its chats. A new file started here is nearly always a note ABOUT the project —
    /// a plan, a scratch list, something to hand an agent — and that is where those live.
    /// Only the default: the save panel opens on it and goes wherever it is taken.
    public static func defaultFolder(in projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(".ultra", isDirectory: true)
    }

    /// A name for the save panel's field that is not already taken in `folder`:
    /// `untitled.md`, then `untitled-2.md`. Markdown, because that is what everything else
    /// in `.ultra/` is written in; the extension is the user's to change in the panel.
    public static func suggestedName(in folder: URL) -> String {
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        if !taken.contains("untitled.md") { return "untitled.md" }
        var number = 2
        while taken.contains("untitled-\(number).md") { number += 1 }
        return "untitled-\(number).md"
    }
}

/// Cancels its sources when it dies, from whatever context that happens to be.
private final class WatchBox: @unchecked Sendable {
    var sources: [DispatchSourceFileSystemObject] = []
    deinit { sources.forEach { $0.cancel() } }
}
