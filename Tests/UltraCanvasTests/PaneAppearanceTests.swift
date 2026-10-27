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

    /// A throwaway defaults suite with the glass set as asked, so a test does not depend on
    /// which way the shipped default points.
    private func withGlass(_ on: Bool, _ body: () throws -> Void) throws {
        let name = "ultra.tests.paneAppearance.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        defer { suite.removePersistentDomain(forName: name) }
        try Preferences.withStore(suite) {
            Appearance.paneGlass = on
            try body()
        }
    }

    @Test("a pane pinned light is solid white in a dark window, not light glass gone grey")
    func pinnedLight() throws { try withGlass(true) {
        let store = store(appearance: .light)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        #expect(pane.appearance?.name == .aqua)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent > 0.99)
        // Opaque whatever the opacity setting, which defaults to painting nothing at all.
        #expect(colour.alphaComponent == 1)
    } }

    @Test("a pane with no appearance of its own follows the window, glass and all")
    func followsWindow() throws { try withGlass(true) {
        let store = store(appearance: nil)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        #expect(pane.appearance == nil)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent < 0.3)
        #expect(colour.alphaComponent == TerminalTheme.dark.backgroundOpacity)
    } }

    @Test("changing a pane's record repaints it, without rebuilding it")
    func recordChangeRepaints() throws { try withGlass(true) {
        let store = store(appearance: .light)
        let paneID = try #require(store.tree.paneIDs.first)
        let pane = store.surfaces.surface(for: paneID)
        store.surfaces.updateRecord(PaneRecord(kind: .placeholder, title: "Pane",
                                               appearance: .dark), for: paneID)
        #expect(store.surfaces.existingSurface(for: paneID) === pane)
        #expect(pane.appearance?.name == .darkAqua)
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent < 0.3)
    } }

    @Test("glass off, a pane pinned light is still a sheet of white")
    func pinnedLightWithoutGlass() throws { try withGlass(false) {
        let store = store(appearance: .light)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        pane.isFocused = true
        let colour = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(colour.brightnessComponent > 0.99)
        #expect(colour.alphaComponent == 1)
    } }

    @Test("glass off, a pane is frosted, washed by its focus and the window's look",
          arguments: [PaneRecord.Appearance.dark, .light])
    func frostedWithoutGlass(_ look: PaneRecord.Appearance) throws { try withGlass(false) {
        // The pane follows the window; the window is dark or light. (A pane PINNED light
        // is a white sheet, tested above.)
        let store = store(appearance: look == .dark ? .dark : nil)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        pane.appearance = NSAppearance(named: look == .dark ? .darkAqua : .aqua)
        pane.isFocused = true
        let focused = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        pane.isFocused = false
        let unfocused = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        let (wantFocused, wantUnfocused) = look == .dark
            ? (Appearance.frostFocusedTintDark, Appearance.frostUnfocusedTintDark)
            : (Appearance.frostFocusedTintLight, Appearance.frostUnfocusedTintLight)
        // Black over the blur, never an opaque sheet that would hide it.
        #expect(abs(focused.alphaComponent - wantFocused) < 0.01)
        #expect(abs(unfocused.alphaComponent - wantUnfocused) < 0.01)
        #expect(focused.alphaComponent < 1 && unfocused.alphaComponent < 1)
        // Focus has to show in the wash as well as in the ring.
        #expect(focused.alphaComponent != unfocused.alphaComponent)
    } }

    @Test("glass off, a plain surface is washed as a pane at rest, focused or not")
    func plainSurfaceRestsWithoutGlass() throws { try withGlass(false) {
        // The Agents overview's note: the only pane on its canvas, so the focused one,
        // and the one surface that must not look it.
        let store = store(appearance: .dark)
        let pane = store.surfaces.surface(for: try #require(store.tree.paneIDs.first))
        pane.appearance = NSAppearance(named: .darkAqua)
        pane.isFocused = true
        pane.isPlain = true
        let plain = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(abs(plain.alphaComponent - Appearance.frostUnfocusedTintDark) < 0.01)
        #expect(pane.layer?.shadowOpacity == Float(Token.Space.paneShadowOpacity))
        // And back: a surface that stops being plain is a focused pane again.
        pane.isPlain = false
        let focused = try #require(backdrop(pane)?.usingColorSpace(.sRGB))
        #expect(abs(focused.alphaComponent - Appearance.frostFocusedTintDark) < 0.01)
    } }

    @Test("an old document with no appearance field still decodes")
    func decodesOldRecords() throws {
        let json = #"{"kind":"shell","title":"zsh","icon":"apple.terminal"}"#
        let record = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        #expect(record.appearance == nil)
    }
}
