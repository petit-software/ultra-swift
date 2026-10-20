import AppKit
import Foundation
import Testing
@testable import UltraSimulator
@testable import UltraTiles

/// The pane end to end, against a real booted simulator: a session connects as the pane's
/// does, its view sits in a window, and a click on the view has to change the device and
/// come back as a frame. The bridge's own live tests (`SimulatorLiveTests`) drive the input
/// object directly; this is the path a person's click takes, which those do not cover.
///
///     ULTRA_SIM_LIVE=1 ULTRA_SIM_UDID=<udid> swift test --filter SimulatorPaneLiveTests
@Suite("Simulator pane live", .enabled(if: ProcessInfo.processInfo.environment["ULTRA_SIM_LIVE"] == "1"), .serialized)
struct SimulatorPaneLiveTests {

    @Test("a click on the pane's screen opens a Settings row, and the pane shows it")
    @MainActor
    func clickThroughPane() async throws {
        let devices = try await SimulatorControl.listDevices()
        let wanted = ProcessInfo.processInfo.environment["ULTRA_SIM_UDID"]
        let device = try #require(devices.first { $0.state.isBooted && (wanted == nil || $0.udid == wanted) && !$0.isTablet },
                                  "boot an iPhone simulator first")
        // Settings opened fresh: brought forward over another app by `simctl launch`, it can
        // show and take no touches, which is the device's quirk and not this pane's.
        _ = await SimulatorControl.run(["simctl", "terminate", device.udid, "com.apple.Preferences"], timeout: 10)
        try await SimulatorControl.launch("com.apple.Preferences", on: device.udid)
        try await Task.sleep(for: .seconds(2))

        let session = SimulatorSession(udid: device.udid)
        let view = session.displayView
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 420, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { session.close(); window.orderOut(nil) }
        session.start()
        for _ in 0..<40 where !(session.isLive && view.input != nil) {
            try await Task.sleep(for: .milliseconds(250))
        }
        try #require(session.isLive && view.input != nil, "\(session.liveError ?? "not live")")
        view.layoutSubtreeIfNeeded()

        // General: the first row of the list, about a third of the way down a phone's root.
        let screen = view.screenRect
        let point = view.convert(CGPoint(x: screen.midX, y: screen.maxY - screen.height * 0.365), to: nil)
        func click(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let before = try await screenshot(device.udid, "before")
        let lastFrame = view.lastFrame
        view.mouseDown(with: click(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(80))
        view.mouseUp(with: click(.leftMouseUp))
        try await Task.sleep(for: .seconds(1.5))
        #expect(try await screenshot(device.udid, "after") != before, "the device did not take the click")
        #expect(view.lastFrame > lastFrame, "the pane did not redraw")
        _ = await SimulatorControl.run(["simctl", "terminate", device.udid, "com.apple.Preferences"], timeout: 10)
    }

    private func screenshot(_ udid: String, _ name: String) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ultra-pane-\(name)-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SimulatorControl.screenshot(udid, to: url)
        return try Data(contentsOf: url)
    }
}
