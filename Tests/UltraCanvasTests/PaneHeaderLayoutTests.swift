import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// The pane name is a control — it opens the kind switcher — and the drag handle is an AppKit
/// view laid over the header. Wherever the two overlap, the handle wins and the name goes
/// dead, with nothing anywhere to say so. These lay out a real header in a window and check
/// the handle starts where the name stops.
@Suite("Pane header layout")
@MainActor
struct PaneHeaderLayoutTests {

    /// Trailing cluster: the split pair, 28 wide each, 1 apart, 5 trailing padding.
    private let splitCluster: CGFloat = 62
    /// The same with zoom leading it, which only the focused pane shows.
    private let focusedCluster: CGFloat = 91

    private func pane(width: CGFloat, title: String, subtitle: String? = nil,
                      focused: Bool = false) -> PaneContainerView {
        let kinds = { [PaneKindChoice(kind: .git, title: "Git", symbol: "arrow.trianglehead.branch")] }
        let actions = PaneActions(split: { _, _ in }, close: { _ in }, focus: { _ in },
                                  kinds: kinds, changeKind: { _, _ in })
        let container = PaneContainerView(paneID: LayoutTree.fixturePane(1),
                                          descriptor: PaneDescriptor(title: title, subtitle: subtitle),
                                          kind: .git, content: NSView(), actions: actions)
        container.isFocused = focused
        // SwiftUI reports geometry only for a hosting view that is in a window.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        container.frame = CGRect(x: 0, y: 0, width: width, height: 300)
        window.contentView?.addSubview(container)
        container.layoutSubtreeIfNeeded()
        // The geometry callback lands on a later turn of the run loop.
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            container.layoutSubtreeIfNeeded()
        }
        return container
    }

    @Test("the drag handle starts after the name, not over it")
    func handleClearsTheName() {
        let container = pane(width: 700, title: "a-deliberately-long-pane-name",
                                   subtitle: "~/Repo/somewhere/deep")
        let trailing = container.identityTrailingForTesting
        // Close (28) + a name this long is well past the pre-layout guess.
        #expect(trailing > 120, "the header never reported where its name ends")
        #expect(container.dragHandleFrameForTesting.minX >= trailing)
        #expect(container.dragHandleFrameForTesting.maxX <= 700 - splitCluster)
    }

    /// A working agent names its pane for what it is doing, at length. The name took the
    /// whole band, and a floating pane — moved by that band — could not be moved.
    @Test("a long name leaves a band to pick the pane up by")
    func longNameLeavesABand() {
        let container = pane(width: 320, title: "Refactoring the layout engine and its tests",
                                   subtitle: "claude · ~/Repo/somewhere/deep/inside")
        #expect(container.dragHandleFrameForTesting.width >= PaneHeader.minDragBand)
    }

    @Test("a narrow pane trims the name rather than pushing the split controls")
    func narrowPaneTrimsTheName() {
        let container = pane(width: 180, title: "a-deliberately-long-pane-name",
                                   subtitle: "~/Repo/somewhere/deep")
        let trailing = container.identityTrailingForTesting
        // The name gave way; the split cluster kept its full width at the trailing edge.
        #expect(trailing <= 180 - splitCluster)
        #expect(trailing > 40, "the name collapsed to nothing instead of trimming")
        #expect(container.dragHandleFrameForTesting.width >= 0)
    }

    @Test("the focused pane makes room for zoom, and its drag handle stops short of it")
    func focusedPaneShowsZoom() {
        let container = pane(width: 180, title: "a-deliberately-long-pane-name",
                             subtitle: "~/Repo/somewhere/deep", focused: true)
        #expect(container.identityTrailingForTesting <= 180 - focusedCluster)
        let wide = pane(width: 700, title: "name", focused: true)
        #expect(wide.dragHandleFrameForTesting.maxX <= 700 - focusedCluster)
    }
}
