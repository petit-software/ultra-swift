import CoreGraphics
import SwiftUI
import Testing
@testable import UltraDesign

/// Three tabs, 100, 60 and 80 wide, 2pt apart, 4pt in from the strip's ends — the belt's
/// own spacing and inset. Starts: 4, 106, 168. Middles: 54, 136, 208.
private let strip = TabStripReorder(widths: [100, 60, 80], spacing: 2, leading: 4)

@Suite("Tab strip reorder")
struct TabStripReorderTests {

    @Test("a tab that has not moved lands where it started")
    func stillInPlace() {
        for index in strip.widths.indices {
            #expect(strip.destination(dragging: index, minX: strip.minX(of: index)) == index)
        }
    }

    @Test("a tab lands past a neighbour only once its middle passes the neighbour's middle")
    func passesMiddles() {
        // Tab 0's middle is 50 past its start. Tab 1's middle is at 136, so tab 0's start
        // has to pass 86.
        #expect(strip.destination(dragging: 0, minX: 85) == 0)
        #expect(strip.destination(dragging: 0, minX: 87) == 1)
        // Past tab 2's middle, 208: a start past 158.
        #expect(strip.destination(dragging: 0, minX: 159) == 2)
        // Leftwards: tab 2 (middle 40 past its start) passes tab 1's middle at a start < 96.
        #expect(strip.destination(dragging: 2, minX: 97) == 2)
        #expect(strip.destination(dragging: 2, minX: 95) == 1)
        #expect(strip.destination(dragging: 2, minX: 4) == 0)
    }

    @Test("the tabs between the start and the landing slide by the dragged tab's width")
    func shifts() {
        // Tab 0 to the end: 1 and 2 move left by 100 + 2.
        #expect(strip.shift(of: 1, dragging: 0, to: 2) == -102)
        #expect(strip.shift(of: 2, dragging: 0, to: 2) == -102)
        // Tab 2 to the front: 0 and 1 move right by 80 + 2.
        #expect(strip.shift(of: 0, dragging: 2, to: 0) == 82)
        #expect(strip.shift(of: 1, dragging: 2, to: 0) == 82)
        // Tabs outside the span stay put.
        #expect(strip.shift(of: 2, dragging: 0, to: 1) == 0)
    }

    @Test("the empty slot sits where the dragged tab will land")
    func slot() {
        // Tab 0 to the end lands at 4 + 60 + 2 + 80 + 2 = 148: 144 from where it started.
        #expect(strip.slotOffset(dragging: 0, to: 2) == 144)
        #expect(strip.minX(of: 0) + strip.slotOffset(dragging: 0, to: 2) == 148)
        // Tab 2 to the front lands at 4: 164 left of 168.
        #expect(strip.slotOffset(dragging: 2, to: 0) == -164)
        #expect(strip.slotOffset(dragging: 1, to: 1) == 0)
    }

    @Test("the dragged tab cannot leave the strip")
    func clamps() {
        #expect(strip.contentWidth == 252)
        #expect(strip.clampedMinX(-50, dragging: 1) == 4)
        // 252 - 4 - 60: the last tab's end stays 4pt inside the strip.
        #expect(strip.clampedMinX(500, dragging: 1) == 188)
    }

    @Test("the move offset counts past the target when moving right")
    func moveOffset() {
        var tabs = ["a", "b", "c"]
        tabs.move(fromOffsets: [0], toOffset: TabStripReorder.moveOffset(from: 0, to: 2))
        #expect(tabs == ["b", "c", "a"])
        tabs = ["a", "b", "c"]
        tabs.move(fromOffsets: [2], toOffset: TabStripReorder.moveOffset(from: 2, to: 0))
        #expect(tabs == ["c", "a", "b"])
    }

    @Test("the strip scrolls only near an edge")
    func autoscroll() {
        #expect(TabStripReorder.autoscrollDirection(pointerX: 10, viewportWidth: 300, edge: 24) == -1)
        #expect(TabStripReorder.autoscrollDirection(pointerX: 150, viewportWidth: 300, edge: 24) == 0)
        #expect(TabStripReorder.autoscrollDirection(pointerX: 290, viewportWidth: 300, edge: 24) == 1)
    }
}
