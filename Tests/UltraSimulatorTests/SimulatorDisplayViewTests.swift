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

    @Test("a touch starting at the bottom of the screen, or just below it, is a swipe from the edge")
    func bottomEdge() {
        let view = makeView(width: 600, height: 800)
        let screen = view.screenRect
        // AppKit's y runs up: the screen's bottom is its minY.
        #expect(view.startEdge(for: CGPoint(x: screen.midX, y: screen.minY + 4)) == .bottom)
        #expect(view.startEdge(for: CGPoint(x: screen.midX, y: screen.minY - 4)) == .bottom)
        #expect(view.startEdge(for: CGPoint(x: screen.midX, y: screen.midY)) == .none)
        #expect(view.startEdge(for: CGPoint(x: screen.midX, y: screen.maxY - 4)) == .none)
        #expect(view.startEdge(for: CGPoint(x: screen.minX - 10, y: screen.minY + 4)) == .none)
    }

    @Test("a landscape device's swipe edge is the bottom of the pane, where its home indicator shows")
    func bottomEdgeLandscape() {
        let view = makeView(width: 800, height: 600, angle: 90)
        let screen = view.screenRect
        #expect(view.startEdge(for: CGPoint(x: screen.midX, y: screen.minY + 4)) == .bottom)
        #expect(view.startEdge(for: CGPoint(x: screen.minX + 4, y: screen.midY)) == .none)
    }

    @Test("zoom scales the fitted device about the pane's middle, and touches follow it")
    func zoomScales() throws {
        let view = makeView(width: 600, height: 800)
        let fit = view.fitted
        view.zoom = 2
        view.layoutSubtreeIfNeeded()
        let zoomed = view.fitted
        #expect(abs(zoomed.width - fit.width * 2) < 0.01 && abs(zoomed.height - fit.height * 2) < 0.01)
        #expect(abs(zoomed.midX - 300) < 0.01 && abs(zoomed.midY - 400) < 0.01)
        let centre = try #require(view.ratio(for: CGPoint(x: 300, y: 400)))
        #expect(abs(centre.x - 0.5) < 0.01 && abs(centre.y - 0.5) < 0.01)
        view.zoom = 0.5
        #expect(abs(view.fitted.height - fit.height / 2) < 0.01)
    }

    @Test("zoom is held inside its range, and steps land on the stops")
    func zoomRange() {
        let view = makeView(width: 600, height: 800)
        view.zoom = 10
        #expect(view.zoom == SimulatorDisplayView.zoomRange.upperBound)
        view.zoom = 0.01
        #expect(view.zoom == SimulatorDisplayView.zoomRange.lowerBound)
        #expect(SimulatorDisplayView.zoomStep(from: 1, in: true) == 1.25)
        #expect(SimulatorDisplayView.zoomStep(from: 1, in: false) == 0.75)
        #expect(SimulatorDisplayView.zoomStep(from: 1.1, in: true) == 1.25)
        #expect(SimulatorDisplayView.zoomStep(from: 1.1, in: false) == 1)
        #expect(SimulatorDisplayView.zoomStep(from: 4, in: true) == 4)
        #expect(SimulatorDisplayView.zoomStep(from: 0.25, in: false) == 0.25)
    }

    @Test("scrolling pans a device larger than the pane, only as far as its edges")
    func panning() throws {
        let view = makeView(width: 600, height: 800)
        view.zoom = 3
        view.layoutSubtreeIfNeeded()
        let before = view.fitted
        // A long scroll: the device's edge stops at the pane's, and never leaves a gap.
        for _ in 0..<50 {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                             wheel1: 40, wheel2: 40, wheel3: 0))
            view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
        }
        let after = view.fitted
        #expect(after != before)
        #expect(after.minX <= 0.01 && after.maxX >= 599.99)
        #expect(after.minY <= 0.01 && after.maxY >= 799.99)
    }

    @Test("no framebuffer means no screen and no touches")
    func empty() {
        let view = SimulatorDisplayView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        #expect(view.fitted == .zero)
        #expect(view.ratio(for: CGPoint(x: 150, y: 150)) == nil)
        #expect(!view.acceptsFirstResponder)
    }
}

/// The enclosure: where Xcode's nine-part frame and its buttons land round a screen.
@Suite("Device chrome geometry")
@MainActor
struct DeviceChromeTests {

    private let sizing = DeviceChrome.Insets(top: 18, left: 18, bottom: 18, right: 18)

    @Test("the body is the screen outset by the frame's sizing")
    func body() {
        let layout = DeviceChrome.geometry(screen: CGSize(width: 402, height: 874), sizing: sizing, buttons: [])
        #expect(layout.size == CGSize(width: 438, height: 910))
        #expect(layout.body == CGRect(x: 0, y: 0, width: 438, height: 910))
        #expect(layout.screen == CGRect(x: 18, y: 18, width: 402, height: 874))
    }

    @Test("side buttons stand proud of the body, and the whole moves to make room")
    func buttons() {
        // iPhone 17's: a volume key on the left and the power key on the right, 8pt out.
        let volume = DeviceChrome.ButtonPlacement(size: CGSize(width: 16, height: 64), anchor: .left,
                                                  trailing: false, offset: CGPoint(x: 8, y: 221))
        let power = DeviceChrome.ButtonPlacement(size: CGSize(width: 16, height: 101), anchor: .right,
                                                 trailing: false, offset: CGPoint(x: -8, y: 262))
        let layout = DeviceChrome.geometry(screen: CGSize(width: 402, height: 874), sizing: sizing,
                                           buttons: [volume, power])
        #expect(layout.size == CGSize(width: 438 + 16, height: 910))
        #expect(layout.body.minX == 8)
        #expect(layout.buttons[0] == CGRect(x: 0, y: 221, width: 16, height: 64))
        #expect(layout.buttons[1] == CGRect(x: 8 + 438 - 8, y: 262, width: 16, height: 101))
        #expect(layout.screen.minX == CGFloat(8 + 18))
    }

    @Test("a top button aligned trailing counts from the right")
    func topTrailing() {
        let power = DeviceChrome.ButtonPlacement(size: CGSize(width: 60, height: 16), anchor: .top,
                                                 trailing: true, offset: CGPoint(x: -74, y: 8))
        let layout = DeviceChrome.geometry(screen: CGSize(width: 100, height: 200), sizing: sizing, buttons: [power])
        #expect(layout.body.minY == 8)
        #expect(layout.buttons[0].maxX == layout.body.maxX - 74)
        #expect(layout.buttons[0].minY == 0)
    }

    @Test("with an enclosure, touches land only on the screen inside it")
    func touchesInEnclosure() throws {
        let view = SimulatorDisplayView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.pixelSize = CGSize(width: 1206, height: 2622)
        let layout = DeviceChrome.geometry(screen: CGSize(width: 402, height: 874), sizing: sizing, buttons: [])
        let image = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        view.chrome = DeviceChrome(image: image, size: layout.size, screen: layout.screen, screenMask: nil)
        view.layoutSubtreeIfNeeded()
        let device = view.fitted
        let screen = view.screenRect
        #expect(device.contains(screen) && screen.width < device.width)
        // The bezel is not the screen.
        #expect(view.ratio(for: CGPoint(x: device.minX + 2, y: device.midY)) == nil)
        let centre = try #require(view.ratio(for: CGPoint(x: screen.midX, y: screen.midY)))
        #expect(abs(centre.x - 0.5) < 0.01 && abs(centre.y - 0.5) < 0.01)
        let topLeft = try #require(view.ratio(for: CGPoint(x: screen.minX + 0.5, y: screen.maxY - 0.5)))
        #expect(topLeft.x < 0.01 && topLeft.y < 0.01)
    }

    @Test("a device's own screen corners load without its enclosure, at the screen's aspect")
    func cornerMask() throws {
        let profile = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17.simdevicetype"
        guard FileManager.default.fileExists(atPath: profile) else { return }
        let mask = try #require(DeviceChrome.cornerMask(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"))
        #expect(abs(Double(mask.width) / Double(mask.height) - 1206.0 / 2622.0) < 0.01)
        #expect(DeviceChrome.cornerMask(deviceType: "com.example.no-such-device") == nil)
    }

    @Test("Xcode's iPhone 17 enclosure loads, when Xcode is here")
    func loadsFromXcode() throws {
        let profile = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/iPhone 17.simdevicetype"
        guard FileManager.default.fileExists(atPath: profile) else { return }
        let chrome = try #require(DeviceChrome.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17"))
        #expect(abs(chrome.screen.width - 402) < 0.5)
        #expect(abs(chrome.screen.height - 874) < 0.5)
        #expect(chrome.size.width > chrome.screen.width)
        #expect(chrome.screenMask != nil)
    }
}
