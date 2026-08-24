import Testing
import AppKit
import Foundation
@testable import UltraTerminal
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// The store is covered in `UltraCoreTests`. These cover the reach: a live pane's history
/// into a file and back onto a new pane's screen — the part that was missing for font and
/// theme, where the factory worked and nothing called it.
@Suite("Scrollback survives a relaunch", .serialized)
@MainActor
struct ScrollbackTests {

    private func temporaryStore() -> (ScrollbackStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ultra-scrollback-live-\(UUID().uuidString)")
        return (ScrollbackStore(directory: dir), dir)
    }

    private func factory(_ store: ScrollbackStore,
                         restoring records: [PaneID: PaneRecord] = [:]) -> ShellPaneFactory {
        ShellPaneFactory(theme: .dark, defaultDirectory: NSTemporaryDirectory(),
                         restoring: records, scrollback: store)
    }

    @Test("what a shell printed is on screen again after a restart")
    func historyComesBack() {
        let (store, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paneID = PaneID()

        let first = factory(store)
        _ = first.makeContent(for: paneID)
        let shell = try! #require(first.shells[paneID])
        shell.feed(text: "the-thing-that-was-printed\r\n")
        first.saveScrollback()

        // A second launch: same pane id, restored from a record, brand new views.
        let record = PaneRecord(kind: .shell, title: "shell", cwd: NSTemporaryDirectory())
        let second = factory(store, restoring: [paneID: record])
        _ = second.makeContent(for: paneID)
        // History is replayed from here, not from `makeContent` — a view that has not been
        // laid out yet would wrap it at SwiftTerm's default 80 columns.
        second.startPendingShells()
        let restored = try! #require(second.shells[paneID])

        #expect(restored.historyText.contains("the-thing-that-was-printed"))
        second.release(paneID)
    }

    /// Restored text is not this session and has to be legible as such: nothing above the
    /// rule ran in this shell, and none of it can be re-run by pressing up.
    @Test("restored history is marked off from the live session")
    func restoredHistoryIsMarked() {
        let (store, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paneID = PaneID()
        store.save("old output\n", for: paneID)

        let record = PaneRecord(kind: .shell, title: "shell", cwd: NSTemporaryDirectory())
        let subject = factory(store, restoring: [paneID: record])
        _ = subject.makeContent(for: paneID)
        subject.startPendingShells()
        let shell = try! #require(subject.shells[paneID])

        #expect(shell.historyText.contains("restored"), "no boundary between old and live")
        subject.release(paneID)
    }

    /// A brand new pane must not inherit a history file that happens to share its id — and
    /// more importantly, must not show one at all.
    @Test("a pane that is not being restored starts empty")
    func freshPaneHasNoHistory() {
        let (store, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paneID = PaneID()
        store.save("history from somewhere else\n", for: paneID)

        let subject = factory(store)          // no records: this is a NEW pane
        _ = subject.makeContent(for: paneID)
        subject.startPendingShells()
        let shell = try! #require(subject.shells[paneID])

        #expect(!shell.historyText.contains("history from somewhere else"))
        subject.release(paneID)
    }

    /// Closing a pane is the clearest available statement that the user is done with what
    /// was in it, and its id is never issued again.
    @Test("closing a pane discards its history")
    func closingDiscards() {
        let (store, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paneID = PaneID()

        let subject = factory(store)
        _ = subject.makeContent(for: paneID)
        subject.shells[paneID]?.feed(text: "output\r\n")
        subject.saveScrollback()
        #expect(store.load(for: paneID) != nil, "the test needs something to discard")

        subject.release(paneID)
        #expect(store.load(for: paneID) == nil)
    }

    /// The ALT buffer is a scratch screen with no scrollback — a pane sitting in `vim` has
    /// one up. Saving it would restore a snapshot of a full-screen app the user has left,
    /// with the session history they actually wanted thrown away.
    @Test("a pane in a full-screen program still saves its session, not the alt screen")
    func altScreenIsNotWhatIsSaved() {
        let (store, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paneID = PaneID()

        let subject = factory(store)
        _ = subject.makeContent(for: paneID)
        let shell = try! #require(subject.shells[paneID])
        shell.feed(text: "session-history\r\n")
        // Switch to the alternate buffer and paint something else, as vim would.
        shell.feed(text: "\u{1b}[?1049h")
        shell.feed(text: "ALT-SCREEN-CONTENT\r\n")

        #expect(shell.historyText.contains("session-history"))
        #expect(!shell.historyText.contains("ALT-SCREEN-CONTENT"))
        subject.release(paneID)
    }

    /// Turning the setting off must not leave the store holding files nobody will read.
    @Test("a factory with no store neither reads nor writes history")
    func storeIsOptional() {
        let paneID = PaneID()
        let subject = ShellPaneFactory(theme: .dark, defaultDirectory: NSTemporaryDirectory())
        _ = subject.makeContent(for: paneID)
        subject.saveScrollback()          // must not crash, must not touch the real directory
        subject.release(paneID)
    }
}

@Suite("Terminal renderer", .serialized)
@MainActor
struct RendererTests {

    @Test("the GPU renderer is off unless asked for")
    func offByDefault() {
        let name = "ultra.tests.renderer.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            #expect(Preferences.useMetalRenderer == false)
        }
    }

    @Test("the setting reaches a shell that already exists")
    func settingReachesLiveShell() {
        let name = "ultra.tests.renderer.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        Preferences.withStore(suite) {
            let factory = ShellPaneFactory(theme: .dark, defaultDirectory: NSTemporaryDirectory())
            let paneID = PaneID()
            _ = factory.makeContent(for: paneID)
            let shell = try! #require(factory.shells[paneID])
            #expect(shell.wantsMetalRenderer == false)

            Preferences.useMetalRenderer = true
            factory.applyRenderer()

            #expect(shell.wantsMetalRenderer == true)
            factory.release(paneID)
        }
    }

    /// A view with no window cannot turn Metal on — SwiftTerm binds the renderer to the
    /// window's screen to pick a scale factor. Asking anyway must be a no-op rather than a
    /// crash, because that is the state every pane is in for the moment between being built
    /// and being placed.
    @Test("asking for the GPU before the pane is on screen is harmless")
    func noWindowIsSafe() {
        let view = ShellTerminalView(spec: ShellSpec())
        view.wantsMetalRenderer = true
        view.applyRenderer()
        #expect(view.isUsingMetalRenderer == false)
    }
}
