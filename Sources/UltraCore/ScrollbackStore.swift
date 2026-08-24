import Foundation

/// Saved terminal scrollback, one file per pane.
///
/// **Deliberately NOT in `WorkspaceDocument`.** That document is re-encoded and rewritten on
/// every divider drag, focus change and title update; scrollback is up to a hundred kilobytes
/// per pane and would turn each of those into a large write. It is also `Equatable` and
/// compared on change, which a megabyte of text would make expensive for no gain. Sidecar
/// files keyed by pane are written only when a pane's history actually needs saving.
///
/// What is stored is PLAIN TEXT — what the screen showed, with colour and every other escape
/// sequence already consumed by the parser. Restored history is decoration, not a replayable
/// session, and this is the difference that makes restoring it safe. See `sanitized(_:)`.
public final class ScrollbackStore: @unchecked Sendable {
    public let directory: URL

    /// Per-pane cap, applied to the TAIL of the history.
    ///
    /// The end is the part worth keeping: it is the last thing an agent said and the prompt
    /// the user was looking at. Truncating the tail to keep the head would preserve the
    /// beginning of a session nobody is coming back to.
    public let limitBytes: Int

    public init(directory: URL? = nil, limitBytes: Int = 128 * 1024) {
        self.directory = directory ?? Self.defaultDirectory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ultra/scrollback", isDirectory: true)
    }

    public func url(for paneID: UUID) -> URL {
        directory.appendingPathComponent("\(paneID.uuidString).txt")
    }

    // MARK: - Write

    /// Save a pane's history, trimmed to the tail and stripped of control bytes.
    ///
    /// History that is entirely blank is DISCARDED rather than written: a pane that never
    /// produced output would otherwise restore to a rule announcing nothing above it.
    public func save(_ text: String, for paneID: UUID) {
        let cleaned = Self.trimmingTrailingBlankLines(Self.sanitized(text))
        let trimmed = Self.tail(of: cleaned, limitBytes: limitBytes)
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            discard(for: paneID)
            return
        }
        try? Data(trimmed.utf8).write(to: url(for: paneID), options: .atomic)
    }

    // MARK: - Read

    /// A pane's saved history, or nil if it has none.
    ///
    /// Sanitized on the way OUT as well as on the way in, and that is the load-bearing one:
    /// what was written being clean says nothing about what is on disk NOW. These files sit
    /// in Application Support, and anything that can write there could put escape sequences
    /// in one. Feeding those to a VT parser is handing an arbitrary file control of the
    /// terminal — the same reasoning that keeps the agent channel off the tty in M4c, and it
    /// applies with more force here, because restoring is something the app does at launch
    /// without anybody asking.
    public func load(for paneID: UUID) -> String? {
        guard let data = try? Data(contentsOf: url(for: paneID)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let cleaned = Self.sanitized(text)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : cleaned
    }

    public func discard(for paneID: UUID) {
        try? FileManager.default.removeItem(at: url(for: paneID))
    }

    /// Drop the history of panes that no longer exist.
    ///
    /// Without this the directory grows for the life of the install: a pane ID is never
    /// reused, so every pane ever closed would leave its history behind forever.
    public func prune(keeping live: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "txt" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Text handling

    /// Strip everything that could steer a terminal, keeping newline.
    ///
    /// C0 controls, DEL, and the C1 range are all removed. ESC is the one that matters —
    /// with it gone there is no way to begin a control sequence, so what is fed back can only
    /// ever be printed. Tab is kept: it is a layout character in this context, not a command,
    /// and stripping it would collapse every indented line of restored output.
    ///
    /// Carriage returns are dropped rather than kept, because a lone CR moves the cursor to
    /// the start of the line and the following text overwrites what is already there — a
    /// saved progress bar would erase the line above it on restore.
    static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            if scalar.value < 0x20 { return false }          // C0, including ESC and CR
            if scalar.value == 0x7F { return false }         // DEL
            if (0x80...0x9F).contains(scalar.value) { return false }  // C1
            return true
        }.map(Character.init))
    }

    /// Drop the empty rows at the end of a terminal grid.
    ///
    /// A terminal is a fixed grid, so a pane showing three lines of output also holds twenty
    /// blank rows below them — and they are as real to `getBufferAsData` as the text is.
    /// Saved unchanged, every relaunch would restore its wall of whitespace and then stack
    /// the next session's on top, so the boundary rule marched steadily down the screen.
    ///
    /// Only the TRAILING run goes. Blank lines in the middle are output the user's commands
    /// actually produced, and closing those gaps would be rewriting what they saw.
    static func trimmingTrailingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The last `limitBytes` of text, cut on a line boundary.
    ///
    /// Cutting mid-line would leave a first line beginning in the middle of a word, which
    /// reads as corruption rather than as truncation. Cutting by BYTES rather than characters
    /// is deliberate — the cap is about file size — and splitting a UTF-8 scalar is avoided
    /// by only ever cutting at a newline, which is single-byte in UTF-8.
    static func tail(of text: String, limitBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > limitBytes else { return text }
        let cut = data.suffix(limitBytes)
        // Drop the partial first line. `firstIndex(of:)` on a slice returns an index into the
        // ORIGINAL data, which is why this searches the slice's own indices.
        guard let newline = cut.firstIndex(of: 0x0A) else {
            return String(decoding: cut, as: UTF8.self)
        }
        return String(decoding: cut[cut.index(after: newline)...], as: UTF8.self)
    }
}
