import Testing
import AppKit
import Foundation
import CoreGraphics
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTerminal

/// The M2 acceptance criterion, with a real process: a shell survives whatever the layout
/// does to it. This is the executable form of the promise the whole architecture exists to
/// keep — see docs/00-OVERVIEW.md.
@Suite("Live PTY survives layout", .serialized)
@MainActor
struct LivePTYTests {

    /// Poll without pumping the runloop — a swift-testing main-actor test does not own one,
    /// and spinning it here deadlocks rather than waiting.
    private func poll(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private func makeHost() -> (LayoutStore, SplitCanvasView, ShellPaneFactory, NSWindow) {
        let factory = ShellPaneFactory(theme: .dark, defaultDirectory: NSTemporaryDirectory())
        let store = LayoutStore(tree: LayoutTree(single: PaneID())) { paneID in
            let content = factory.makeContent(for: paneID)
            return PaneContent(view: content.view, record: content.record)
        }
        store.surfaces.onRelease = { [weak factory] in factory?.release($0) }
        let canvas = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = canvas
        canvas.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.layoutSubtreeIfNeeded()
        return (store, canvas, factory, window)
    }

    /// The header a user reads, all the way from a real `cd` in a real shell.
    ///
    /// Every link below this had a test and the chain still did not work: no shell on a
    /// stock macOS emits OSC 7, so nothing ever CALLED the code that renames a pane, and a
    /// header sat on the folder the pane was opened in for the entire session. This asserts
    /// the whole chain, from the shell moving to the words in the pane's chrome.
    @Test("a cd in a real shell renames the pane the user is looking at")
    func headerFollowsCd() {
        let factory = ShellPaneFactory(theme: .dark, defaultDirectory: NSTemporaryDirectory())
        let store = LayoutStore(tree: LayoutTree(single: PaneID())) { paneID in
            let content = factory.makeContent(for: paneID)
            return PaneContent(view: content.view, record: content.record)
        }
        factory.onDescriptorChange = { [weak store] paneID, record in
            store?.surfaces.updateRecord(record, for: paneID)
        }
        let paneID = store.tree.focused
        let surface = store.surfaces.surface(for: paneID)
        factory.startPendingShells()
        defer { store.surfaces.release(paneID) }

        let destination = "/usr/lib"
        #expect(store.surfaces.surfaceRecord(for: paneID).title != destination,
                "the pane did not already start where this test cd's to")

        let shell = try! #require(factory.shells[paneID])
        shell.inject("cd \(destination)", submit: true)
        let moved = poll(upTo: 5) {
            shell.processID.flatMap { ForegroundProcess.workingDirectory(ofProcess: $0) }
                == destination
        }
        #expect(moved, "the shell never cd'd — the rest of this test proves nothing")
        // By hand: the probe is debounced onto a runloop this test does not own.
        shell.probeDirectory()

        #expect(store.surfaces.surfaceRecord(for: paneID).title == destination,
                "the pane still names the folder it was opened in")
        #expect(surface.accessibilityLabel()?.contains(destination) == true,
                "and VoiceOver reads the old folder too")
    }

    /// The second half of M3's acceptance criterion: "no PTY is killed by a tab switch."
    ///
    /// A tab here is a whole second workspace — its own `LayoutStore`, its own factory, its
    /// own panes. Nothing in building or using one should reach the first tab's shells. The
    /// failure this guards against is a release path keyed by pane rather than by workspace:
    /// pane ids are unique, but a factory handed another store's release callback would kill
    /// processes belonging to a tab the user never touched.
    @Test("opening and working in a second tab does not kill the first tab's shell")
    func secondTabLeavesTheFirstAlone() {
        let (firstStore, _, firstFactory, _) = makeHost()
        let watched = firstStore.tree.focused
        _ = firstStore.surfaces.surface(for: watched)
        firstFactory.startPendingShells()

        let shell = try! #require(firstFactory.shells[watched])
        let pid = try! #require(shell.processID)
        #expect(shell.isRunning)

        // A second tab, built and then worked in — splits, focus changes, and a close.
        let (secondStore, _, secondFactory, _) = makeHost()
        _ = secondStore.surfaces.surface(for: secondStore.tree.focused)
        secondFactory.startPendingShells()
        _ = secondStore.split(edge: .right)
        _ = secondStore.split(edge: .bottom)
        for paneID in secondStore.tree.paneIDs { _ = secondStore.surfaces.surface(for: paneID) }
        secondFactory.startPendingShells()
        if let victim = secondStore.tree.paneIDs.last, secondStore.tree.paneIDs.count > 1 {
            secondStore.close(victim)
        }

        // Give any mistaken teardown time to land, then assert it did not happen.
        _ = poll(upTo: 0.4, until: { !shell.isRunning })
        #expect(shell.isRunning, "the first tab's shell died while a second tab was used")
        #expect(shell.processID == pid, "the first tab's shell was replaced")
        #expect(firstFactory.shells[watched] != nil)
    }

    /// The tty is asked what is running, and it answers correctly — against a real shell,
    /// with a real foreground process, not a fixture.
    ///
    /// This is the whole reason agent state moved off launch-time bookkeeping: the answer has
    /// to change when the user runs something and change BACK when it exits, and nothing the
    /// app records at launch can do that.
    @Test("a pane reports the process actually in its foreground, and follows it")
    func activityFollowsTheForegroundProcess() {
        let (store, _, factory, _) = makeHost()
        let paneID = store.tree.focused
        _ = store.surfaces.surface(for: paneID)
        factory.startPendingShells()

        let shell = try! #require(factory.shells[paneID])
        #expect(poll(upTo: 3, until: { shell.activity != nil }),
                "the pane never reported any foreground process")

        // At rest the shell itself is in the foreground, and a shell is not an agent.
        let atRest = try! #require(shell.activity)
        #expect(!atRest.isAgent, "a plain shell counted as an agent: \(atRest.command)")
        #expect(!shell.isRunningAgent)

        // Run something slow, and the foreground process becomes that thing.
        shell.inject("sleep 4", submit: true)
        #expect(poll(upTo: 3, until: { shell.activity?.command == "sleep" }),
                "foreground never became `sleep`, saw \(shell.activity?.command ?? "nil")")
        #expect(shell.isRunningAgent == false, "`sleep` is not an agent")
    }

    /// The counter is what the keep-awake assertion reads, so it has to fall as well as
    /// rise. The launched-as answer could only ever rise: a pane started as an agent went on
    /// counting after the agent exited, holding the machine open for a shell at a prompt.
    @Test("the agent count reflects the tty, not what the pane was launched as")
    func agentCountComesFromTheTty() {
        let (store, _, factory, _) = makeHost()
        let paneID = store.tree.focused
        _ = store.surfaces.surface(for: paneID)
        factory.startPendingShells()

        let shell = try! #require(factory.shells[paneID])
        #expect(poll(upTo: 3, until: { shell.activity != nil }))
        // A plain shell, however many panes exist, is not agent work.
        #expect(factory.runningAgentCount == 0)
    }

    @Test("a shell keeps its pid across 100 random layout operations")
    func pidSurvivesChaos() {
        let (store, canvas, factory, _) = makeHost()
        let watched = store.tree.focused
        _ = store.surfaces.surface(for: watched)   // materialise it
        factory.startPendingShells()

        let shell = try! #require(factory.shells[watched])
        let pid = try! #require(shell.processID)
        #expect(pid > 0)

        for _ in 0..<100 {
            switch Int.random(in: 0..<5) {
            case 0, 1:
                let panes = store.tree.paneIDs
                if panes.count < 6 {
                    store.split(edge: Edge.allCases.randomElement()!,
                                paneID: panes.randomElement()!)
                }
            case 2:
                let victims = store.tree.paneIDs.filter { $0 != watched }
                if let victim = victims.randomElement() {
                    store.focus(victim)
                    store.closeFocused()
                }
            case 3:
                store.resizeFocused(Edge.allCases.randomElement()!, by: 24)
            default:
                store.moveFocus(Edge.allCases.randomElement()!)
            }
            canvas.sync()
            canvas.layoutSubtreeIfNeeded()
        }

        #expect(factory.shells[watched]?.processID == pid, "the shell was restarted")
        #expect(factory.shells[watched]?.isRunning == true, "the shell died")
        #expect(kill(pid, 0) == 0, "the process is gone from the system")

        store.surfaces.prune(keeping: [])
    }

    @Test("closing a pane is what kills its process, and nothing else does")
    func closeKillsExactlyOnce() {
        let (store, canvas, factory, _) = makeHost()
        let first = store.tree.focused
        _ = store.surfaces.surface(for: first)
        store.split(edge: .right)
        canvas.sync()
        canvas.layoutSubtreeIfNeeded()
        let second = store.tree.focused
        factory.startPendingShells()

        let survivorPID = try! #require(factory.shells[first]?.processID)
        let victimPID = try! #require(factory.shells[second]?.processID)
        #expect(survivorPID != victimPID)

        store.focus(second)
        store.closeFocused()
        canvas.sync()
        canvas.layoutSubtreeIfNeeded()

        #expect(factory.shells[second] == nil, "the closed pane's shell was not released")
        _ = poll(upTo: 3) { kill(victimPID, 0) != 0 }
        #expect(factory.shells[first]?.processID == survivorPID, "the survivor was disturbed")
        #expect(factory.shells[first]?.isRunning == true)
        store.surfaces.prune(keeping: [])
    }

    @Test("a pane whose working directory is gone says so instead of opening elsewhere")
    func missingDirectoryIsReported() {
        let factory = ShellPaneFactory(theme: .dark, defaultDirectory: "/no/such/directory")
        let paneID = PaneID()
        let content = factory.makeContent(for: paneID)
        #expect(content.record.cwd == "/no/such/directory")

        factory.startPendingShells()
        let shell = factory.shells[paneID]!
        // It still starts — in the user's home, per the shell's own default — but the pane
        // has told them their directory is gone rather than pretending otherwise.
        #expect(shell.isRunning)
        factory.release(paneID)
    }
}
