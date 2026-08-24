import Testing
import Foundation
@testable import UltraCore

@Suite("Scrollback storage")
struct ScrollbackStoreTests {

    private func store(limitBytes: Int = 128 * 1024) -> (ScrollbackStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-scrollback-\(UUID().uuidString)")
        return (ScrollbackStore(directory: dir, limitBytes: limitBytes), dir)
    }

    @Test("history round-trips")
    func roundTrip() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        subject.save("first line\nsecond line\n", for: pane)
        #expect(subject.load(for: pane) == "first line\nsecond line\n")
    }

    @Test("a pane with no history has nothing to restore")
    func missingIsNil() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(subject.load(for: UUID()) == nil)
    }

    /// A terminal buffer is mostly blank rows. Writing them would mean a pane that produced
    /// no output still restores under a rule announcing the history above it — of which there
    /// is none.
    @Test("blank history is discarded rather than written")
    func blankIsNotWritten() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        subject.save("\n\n   \n\n", for: pane)
        #expect(subject.load(for: pane) == nil)
        #expect(!FileManager.default.fileExists(atPath: subject.url(for: pane).path))
    }

    /// THE security property. These files sit in Application Support as plain text; anything
    /// that can write there could put escape sequences in one, and restoring is something the
    /// app does at launch without being asked. An ESC that survived would let a file drive
    /// the terminal — set the title, move the cursor, or on a permissive emulator worse.
    @Test("escape sequences in a history file cannot reach the terminal")
    func escapesAreStripped() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        // Written straight to disk, bypassing `save`, because the threat is a file that was
        // never written by us at all.
        let hostile = "safe\n\u{1b}]0;pwned\u{07}\u{1b}[2J\u{1b}[31mred\nmore\n"
        try! Data(hostile.utf8).write(to: subject.url(for: pane))

        let restored = try! #require(subject.load(for: pane))
        #expect(!restored.contains("\u{1b}"), "an ESC survived — the file can drive the terminal")
        #expect(!restored.contains("\u{07}"))
        // The readable text is kept; only the steering is removed.
        #expect(restored.contains("safe"))
        #expect(restored.contains("red"))
        #expect(restored.contains("pwned"), "the title text itself is harmless once ESC is gone")
    }

    /// A lone CR returns the cursor to the column zero and what follows overwrites the line.
    /// A saved progress bar full of them would eat the lines around it on restore.
    @Test("carriage returns are dropped, tabs are kept")
    func controlCharacterPolicy() {
        #expect(ScrollbackStore.sanitized("a\r\nb") == "a\nb")
        #expect(ScrollbackStore.sanitized("a\tb") == "a\tb")
        #expect(ScrollbackStore.sanitized("a\u{7F}b") == "ab")
        #expect(ScrollbackStore.sanitized("a\u{0}b") == "ab")
    }

    @Test("unicode survives sanitising")
    func unicodeSurvives() {
        let text = "→ ✓ é 日本語 🎉\n"
        #expect(ScrollbackStore.sanitized(text) == text)
    }

    /// The END of a session is the part worth keeping — the last thing an agent said and the
    /// prompt the user was looking at.
    @Test("an over-long history keeps its tail, not its head")
    func tailIsKept() {
        let (subject, dir) = store(limitBytes: 200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        let text = (0..<200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        subject.save(text, for: pane)

        let restored = try! #require(subject.load(for: pane))
        #expect(restored.contains("line 199"), "the newest output was thrown away")
        #expect(!restored.contains("line 0\n"), "the oldest output was kept")
        #expect(Data(restored.utf8).count <= 200)
    }

    /// Cutting mid-line reads as corruption rather than as truncation.
    @Test("truncation lands on a line boundary")
    func cutsOnALineBoundary() {
        let text = (0..<100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = ScrollbackStore.tail(of: text, limitBytes: 100)
        let first = try! #require(tail.split(separator: "\n").first)
        #expect(first.hasPrefix("line "), "the first line begins mid-word: \(first)")
    }

    /// Cutting by bytes through a multi-byte scalar would produce replacement characters.
    @Test("a cut through multi-byte characters does not corrupt them")
    func multiByteSafeCut() {
        let text = (0..<200).map { "日本語 \($0)" }.joined(separator: "\n") + "\n"
        let tail = ScrollbackStore.tail(of: text, limitBytes: 300)
        #expect(!tail.contains("\u{FFFD}"), "a UTF-8 scalar was split")
    }

    @Test("history for a pane that no longer exists is pruned")
    func pruning() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = UUID(), gone = UUID()
        subject.save("still here\n", for: live)
        subject.save("closed\n", for: gone)

        subject.prune(keeping: [live])

        #expect(subject.load(for: live) != nil)
        #expect(subject.load(for: gone) == nil, "a closed pane's history outlived it")
    }

    /// A terminal is a fixed grid: a pane showing three lines also holds twenty blank rows
    /// below them, and they are as real to the buffer as the text. Saved unchanged, every
    /// relaunch restores its own wall of whitespace on top of the last one's.
    @Test("the blank rows below the last line are not saved")
    func trailingBlankRowsAreTrimmed() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        subject.save("output\n" + String(repeating: "\n", count: 20), for: pane)
        #expect(subject.load(for: pane) == "output\n")
    }

    /// Gaps in the middle are output the user's commands produced; closing them would be
    /// rewriting what they saw.
    @Test("blank lines inside the history are kept")
    func interiorBlanksSurvive() {
        #expect(ScrollbackStore.trimmingTrailingBlankLines("a\n\n\nb\n\n\n") == "a\n\n\nb\n")
    }

    @Test("discarding removes the file")
    func discarding() {
        let (subject, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        subject.save("text\n", for: pane)
        subject.discard(for: pane)
        #expect(subject.load(for: pane) == nil)
    }
}
