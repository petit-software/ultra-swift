import Testing
import AppKit
import CoreGraphics
@testable import UltraCanvas
@testable import UltraLayout

/// The drop preview is only honest if the layout it shows is the layout the drop commits.
/// If those two ever diverge, panes jump at the instant of release — the exact glitch the
/// live reflow exists to remove.
@Suite("Drop preview")
@MainActor
struct DropPreviewTests {

    private func canvas(_ fixture: LayoutTree.Fixture,
                        size: CGSize = CGSize(width: 1200, height: 800)) -> SplitCanvasView {
        let factory = PlaceholderPaneFactory()
        let store = LayoutStore(tree: .fixture(fixture)) { factory.makeContent(for: $0) }
        let view = SplitCanvasView(store: store)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("the previewed tree is exactly what the drop commits",
          arguments: LayoutTree.Fixture.allCases)
    func previewMatchesCommit(fixture: LayoutTree.Fixture) {
        let view = canvas(fixture)
        let panes = view.store.tree.paneIDs
        guard panes.count > 1 else { return }

        for dragged in panes {
            for target in panes where target != dragged {
                for zone: DropZone in [.centre, .edge(.left), .edge(.right),
                                       .edge(.top), .edge(.bottom)] {
                    guard let preview = view.previewTree(dragging: dragged,
                                                         plan: (target, zone)) else { continue }
                    // Commit the same operation against a fresh copy and compare.
                    var committed = view.store.tree
                    switch zone {
                    case .centre: _ = committed.swap(dragged, target)
                    case .edge(let edge): _ = committed.move(dragged, toEdgeOf: target, edge: edge)
                    }
                    #expect(preview.paneIDs.sorted() == committed.paneIDs.sorted(),
                            "\(fixture) \(zone): preview and commit disagree on panes")
                    let m = LayoutMetrics.default
                    let a = layout(preview, in: view.bounds, metrics: m).frames
                    let b = layout(committed, in: view.bounds, metrics: m).frames
                    #expect(a.keys.sorted() == b.keys.sorted())
                    for (id, frame) in a {
                        #expect(b[id].map { $0.equalTo(frame) } == true,
                                "\(fixture) \(zone): \(id) previewed at \(frame), commits to \(b[id] as Any)")
                    }
                }
            }
        }
    }

    @Test("a preview never loses or duplicates a pane", arguments: LayoutTree.Fixture.allCases)
    func previewPreservesPanes(fixture: LayoutTree.Fixture) {
        let view = canvas(fixture)
        let before = Set(view.store.tree.paneIDs)
        guard before.count > 1 else { return }
        for dragged in before {
            for target in before where target != dragged {
                for zone: DropZone in [.centre, .edge(.left), .edge(.bottom)] {
                    guard let preview = view.previewTree(dragging: dragged,
                                                         plan: (target, zone)) else { continue }
                    #expect(Set(preview.paneIDs) == before)
                    #expect(preview.paneIDs.count == before.count)
                }
            }
        }
    }
}
