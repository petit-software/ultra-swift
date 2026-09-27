import CoreGraphics
import Foundation
import Testing
@testable import UltraSimulator

/// Against a real, booted simulator. Opt-in: these touch whatever device is booted on the
/// machine running them, so they run only with `ULTRA_SIM_LIVE=1` in the environment —
/// never as part of a plain `swift test`.
///
///     ULTRA_SIM_LIVE=1 swift test --filter SimulatorLiveTests
///
/// They are the regression check for the private-API bridge: a new Xcode that moves a
/// class or a selector fails here first.
@Suite("Simulator live", .enabled(if: ProcessInfo.processInfo.environment["ULTRA_SIM_LIVE"] == "1"), .serialized)
struct SimulatorLiveTests {

    @MainActor
    private func bootedDevice() async throws -> (SimulatorDevice, AnyObject) {
        let devices = try await SimulatorControl.listDevices()
        let bootedDevice = devices.first { $0.state.isBooted }
        let booted = try #require(bootedDevice, "boot a simulator first")
        let handle = try SimulatorFrameworks.shared.device(udid: booted.udid)
        return (booted, handle)
    }

    @Test("the frameworks load and the booted device is found")
    @MainActor
    func loads() async throws {
        #expect(SimulatorFrameworks.shared.isAvailable, "\(String(describing: SimulatorFrameworks.shared.error))")
        let (device, handle) = try await bootedDevice()
        #expect(SimulatorFrameworks.shared.state(of: handle) == 3, "\(device.name) reports booted")
    }

    @Test("the display port hands over a framebuffer")
    @MainActor
    func display() async throws {
        let (_, handle) = try await bootedDevice()
        let display = try #require(SimulatorDisplay.find(for: handle))
        #expect(display.surface != nil)
        #expect(display.pixelSize.width > 0 && display.pixelSize.height > 0)
        #expect(display.snapshot() != nil)
    }

    /// A still home screen paints nothing for minutes at a time, so the damage callback is
    /// checked here, where a tap makes something happen.
    @Test("a tap on the home screen changes it and reports frames; Home puts it back")
    @MainActor
    func tap() async throws {
        let (_, handle) = try await bootedDevice()
        let display = try #require(SimulatorDisplay.find(for: handle))
        let input = try SimulatorInput(device: handle)
        var frames = 0
        display.onFrame = { frames += 1 }
        display.start()
        defer { display.stop() }

        // Start from the home screen, so the tap lands on the first row of app icons —
        // any app opening is a full-screen change.
        input.press(.home)
        try await Task.sleep(for: .seconds(1.5))
        let before = try #require(display.snapshot())
        frames = 0

        let icon = CGPoint(x: 0.61, y: 0.14)
        input.touch(.down, at: icon)
        try await Task.sleep(for: .milliseconds(80))
        input.touch(.up, at: icon)
        try await Task.sleep(for: .seconds(2.5))
        let after = try #require(display.snapshot())

        let changed = Self.differingFraction(before, after)
        #expect(changed > 0.05, "only \(changed) of the screen changed after a tap")
        #expect(frames > 0, "no damage callback after the tap")

        input.press(.home)
        try await Task.sleep(for: .seconds(1.5))
    }

    /// The share of pixels that differ, on a coarse grid: enough to tell "an app opened"
    /// from "the clock ticked".
    private static func differingFraction(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return 1 }
        let pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
        let stride = a.bytesPerRow, step = 16
        var differ = 0, total = 0
        for y in Swift.stride(from: 0, to: a.height, by: step) {
            for x in Swift.stride(from: 0, to: a.width, by: step) {
                let i = y * stride + x * 4
                total += 1
                if abs(Int(pa[i]) - Int(pb[i])) > 24 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 24
                    || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 24 {
                    differ += 1
                }
            }
        }
        return total == 0 ? 1 : Double(differ) / Double(total)
    }
}
