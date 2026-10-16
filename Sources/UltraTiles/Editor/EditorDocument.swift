import Foundation
import UltraDesign

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
    /// What the file is when it is shown rather than edited — a picture, a film, a sound,
    /// a PDF. Always binary as well: nothing typed here can be saved over one.
    public private(set) var media: EditorMedia?
    /// Counts the times a media file changed on disk, so the view showing it knows to
    /// load it again: a screenshot taken over the last, an image an agent regenerated.
    public private(set) var mediaRevision = 0
    /// Whether the file is showing as the page it describes rather than as its text —
    /// Markdown's second face, see `MarkdownReadingView`. Decided as the file is opened,
    /// from `Preferences.opensMarkdownReading`, and switched from the footer or Pane ▸
    /// Editor from then on. Never saved anywhere: it is about this sitting, not the file.
    public private(set) var isReading = false

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
    /// When a media file was last written and how big it was. Its folder is watched as
    /// well as the file, so a sibling being written fires the watch too; this is how a
    /// change to the file is told from a change next to it.
    private var mediaStamp: MediaStamp?

    /// What this is called until it has a file. Numbered by `EditorSessions`, so two new
    /// files in one pane can be told apart.
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

    /// A file the editor can show as a page: Markdown, told by its name the way the
    /// highlighter tells it (`.md`, `README`, `CHANGELOG`…). A new file is not one until
    /// its first save names it.
    public var isMarkdown: Bool {
        guard let url else { return false }
        return CodeLanguage.detect(path: url.path)?.scanner == .markdown
    }

    /// Show the page, or the text. Only a Markdown file has a page to show; asked of any
    /// other, this leaves it on its text.
    public func setReading(_ reading: Bool) {
        isReading = reading && isMarkdown && !isBinary
    }

    public func toggleReading() { setReading(!isReading) }

    public var displayName: String { url?.lastPathComponent ?? untitledName }
    /// True until the first save gives it a file. `save()` cannot work on one of these —
    /// the caller has to ask where, and then `save(to:)`.
    public var isUntitled: Bool { url == nil }

    // MARK: Opening and saving

    public func open(_ url: URL) {
        self.url = url
        notice = nil
        isBinary = false
        media = nil
        mediaStamp = nil
        // The page first, when the file has one and the setting says so — including a
        // file not on disk yet, which becomes a page the moment it arrives.
        isReading = Preferences.opensMarkdownReading && isMarkdown
        // A picture, a film, a sound or a PDF is shown, and its bytes are left to the
        // view that shows it: none of them is read here to find out it is not text.
        // Binary from the start, missing or not, so nothing typed can be saved over it.
        if let kind = EditorMedia.kind(of: url) {
            media = kind
            isBinary = true
            savedText = ""; text = ""; isDirty = false
            guard let stamp = MediaStamp(url) else {
                failToRead(url)
                return
            }
            mediaStamp = stamp
            beginWatching()
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            savedText = ""; text = ""; isDirty = false
            failToRead(url)
            return
        }
        // A NUL byte is the practical test for "this is not text". Opening a binary in a
        // text view produces garbage that looks editable, and saving it corrupts the file.
        if data.prefix(8000).contains(0) {
            isBinary = true
            isReading = false
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

    private func failToRead(_ url: URL) {
        notice = .failed("Could not read \(url.lastPathComponent)")
        // Watched all the same. A file opened from a chat's list of changes can be clicked
        // before the engine has written it; the folder watch sees it arrive, and
        // `externalChange` turns this failure into the file.
        beginWatching()
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
        if media != nil {
            mediaChange()
            return
        }
        guard let url, !isBinary,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else { return }
        // A file that could not be read when it was opened is here now. Taken whatever it
        // holds, EMPTY included: a new file is usually empty, and "nothing changed since
        // the failure" would otherwise leave the failure on screen over a file that exists.
        if case .failed = notice {
            savedText = contents
            text = contents
            isDirty = false
            notice = nil
            // The file-level watch could not be taken while the file was missing; now that
            // it exists, both watches are.
            beginWatching()
            return
        }
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

    /// A media file is not compared or merged — it cannot be edited here — only noticed:
    /// when it is written, the view loads it again. No toast: the picture changing is the
    /// news. A file that could not be read and now can becomes the file, as text does.
    private func mediaChange() {
        guard let url, let stamp = MediaStamp(url), stamp != mediaStamp else { return }
        let wasMissing = mediaStamp == nil
        mediaStamp = stamp
        mediaRevision += 1
        if case .failed = notice { notice = nil }
        // The file-level watch could not be taken while the file was missing.
        if wasMissing { beginWatching() }
    }
}

/// When a file was last written and how big it is: enough to tell it changed without
/// reading it. Nil for a file that is not there.
private struct MediaStamp: Equatable {
    let modified: Date?
    let size: Int?

    /// From the file system every time, not `URL.resourceValues`: those are cached on the
    /// URL value, and the document asks through the same one, so a picture written again
    /// kept answering with the date it had when it was opened and was never shown again.
    init?(_ url: URL) {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        modified = attributes[.modificationDate] as? Date
        size = (attributes[.size] as? NSNumber)?.intValue
    }
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
