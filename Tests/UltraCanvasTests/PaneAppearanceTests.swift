import Testing
import AppKit
@testable import UltraCanvas
@testable import UltraCore
@testable import UltraDesign
@testable import UltraLayout

/// A pane can pin its own look — a browser pane showing a white page is painted light, in a
/// dark window — and the canvas, not the tile, is what paints it.
@Suite("A pane's own appearance")
@MainActor
struct PaneAppearanceTests {

    private func store(appearance: PaneRecord.Appearance?) -> LayoutStore {
        LayoutStore(tree: .fixture(.single), theme: .dark) { _ in
            PaneContent(view: NSView(),
                        record: PaneRecord(kind: .placeholder, title: "Pane",
                                           appearance: appearance))
        }
    }

    private func backdrop(_ container: PaneContainerView) -> NSColor? {
        container.backdropColourForTesting.flatMap(NSColor.init(cgColor:))
    }

    @Test("a pane pinned light is solid white in a dark window, not light glass gone grey")
    func pinnedLight() throws {
        let store = store(appearance: .light)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        #expect(pane.appearance?.name == .aqua)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent > 0.99)
        // Opaque whatever the opacity setting, which defaults to painting nothing at all.
        #expect(colour.alphaComponent == 1)
    }

    @Test("a pane with no appearance of its own follows the window, glass and all")
    func followsWindow() throws {
        let store = store(appearance: nil)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        #expect(pane.appearance == nil)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent < 0.3)
        #expect(colour.alphaComponent == TerminalTheme.dark.backgroundOpacity)
    }

    @Test("changing a pane's record repaints it, without rebuilding it")
    func recordChangeRepaints() throws {
        let store = store(appearance: .light)
        let paneID = try #require(store.tree.paneIDs.first)
        let pane = store.surfaces.surface(for: paneID)
        store.surfaces.updateRecord(PaneRecord(kind: .placeholder, title: "Pane",
                                               appearance: .dark), for: paneID)
        #expect(store.surfaces.existingSurface(for: paneID) === pane)
        #expect(pane.appearance?.name == .darkAqua)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent < 0.3)
    }

    @Test("an old document with no appearance field still decodes")
    func decodesOldRecords() throws {
        let json = #"{"kind":"shell","title":"zsh","icon":"apple.terminal"}"#
        let record = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        #expect(record.appearance == nil)
    }
}
