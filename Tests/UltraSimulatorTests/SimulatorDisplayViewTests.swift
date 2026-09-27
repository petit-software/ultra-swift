import AppKit
import Testing
@testable import UltraSimulator

/// The click-to-finger maths, headless: a view with a known size and a known framebuffer,
/// and the ratios its points map to. No device, no window.
@Suite("Simulator display geometry")
@MainActor
struct SimulatorDisplayViewTests {

    private func makeView(width: CGFloat, height: CGFloat, angle: Double = 0) -> SimulatorDisplayView {
        let view = SimulatorDisplayView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.pixelSize = CGSize(width: 1206, height: 2622)   // an iPhone 17
        view.angle = angle
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test("a portrait screen is fitted to the pane's height and centred")
    func portraitFit() {
        let view = makeView(width: 600, height: 800)
        let box = view.fitted
        #expect(abs(box.height - 800) < 0.01)
        #expect(abs(box.width - 800 * 1206 / 2622) < 0.01)
        #expect(abs(box.midX - 300) < 0.01)
    }

    @Test("corners map to the ratio's corners, with y running down the device")
    func corners() throws {
        let view = makeView(width: 600, height: 800)
        let box = view.fitted
        // AppKit's y runs up; the device's runs down. The top-left of the picture is the
        // top-left of the device.
        let topLeft = try #require(view.ratio(for: CGPoint(x: box.minX + 0.5, y: box.maxY - 0.5)))
        #expect(topLeft.x < 0.01 && topLeft.y < 0.01)
        let bottomRight = try #require(view.ratio(for: CGPoint(x: box.maxX - 0.5, y: box.minY + 0.5)))
        #expect(bottomRight.x > 0.99 && bottomRight.y > 0.99)
        let centre = try #require(view.ratio(for: CGPoint(x: box.midX, y: box.midY)))
        #expect(abs(centre.x - 0.5) < 0.01 && abs(centre.y - 0.5) < 0.01)
    }

    @Test("a point in the letterbox is not a touch")
    func outsideIsNil() {
        let view = makeView(width: 600, height: 800)
        #expect(view.ratio(for: CGPoint(x: 5, y: 400)) == nil)
        #expect(view.ratio(for: CGPoint(x: 595, y: 400)) == nil)
    }

    @Test("a landscape device turns the picture and the mapping with it")
    func landscape() throws {
        let view = makeView(width: 800, height: 600, angle: 90)
        let box = view.fitted
        // Now the wide way round: fitted to the pane's width.
        #expect(abs(box.width - 800) < 0.01)
        #expect(abs(box.height - 800 * 1206 / 2622) < 0.01)
        #expect(box.width > box.height)
        // The device's own top-left is now at one end of the long edge; whichever end, the
        // mapping stays inside the unit square and the centre is still the centre.
        let centre = try #require(view.ratio(for: CGPoint(x: box.midX, y: box.midY)))
        #expect(abs(centre.x - 0.5) < 0.01 && abs(centre.y - 0.5) < 0.01)
        let corner = try #require(view.ratio(for: CGPoint(x: box.minX + 0.5, y: box.maxY - 0.5)))
        #expect((0...1).contains(corner.x) && (0...1).contains(corner.y))
        #expect(corner.x < 0.01 || corner.x > 0.99)
        #expect(corner.y < 0.01 || corner.y > 0.99)
    }

    @Test("no framebuffer means no screen and no touches")
    func empty() {
        let view = SimulatorDisplayView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        #expect(view.fitted == .zero)
        #expect(view.ratio(for: CGPoint(x: 150, y: 150)) == nil)
        #expect(!view.acceptsFirstResponder)
    }
}
