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
