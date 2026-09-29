import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import UltraSimulator

/// Against a real, booted simulator. Opt-in: these touch whatever device is booted on the
/// machine running them, so they run only with `ULTRA_SIM_LIVE=1` in the environment —
/// never as part of a plain `swift test`.
///
///     ULTRA_SIM_LIVE=1 swift test --filter SimulatorLiveTests
///
/// With more than one device booted, `ULTRA_SIM_UDID` picks which.
///
/// They are the regression check for the private-API bridge: a new Xcode that moves a
/// class or a selector fails here first.
@Suite("Simulator live", .enabled(if: ProcessInfo.processInfo.environment["ULTRA_SIM_LIVE"] == "1"), .serialized)
struct SimulatorLiveTests {

    @MainActor
    private func bootedDevice() async throws -> (SimulatorDevice, AnyObject) {
        let devices = try await SimulatorControl.listDevices()
        let wanted = ProcessInfo.processInfo.environment["ULTRA_SIM_UDID"]
        let bootedDevice = devices.first { $0.state.isBooted && (wanted == nil || $0.udid == wanted) }
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

    @Test("the display port hands over the device's own screen, not its TV-out")
    @MainActor
    func display() async throws {
        let (device, handle) = try await bootedDevice()
        let display = try #require(SimulatorDisplay.find(for: handle))
        #expect(display.surface != nil)
        let frame = try #require(display.snapshot())
        // `simctl io screenshot` is of the built-in screen: the live framebuffer has to be
        // the same size, whichever order the ports came in.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ultra-live-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await SimulatorControl.screenshot(device.udid, to: file)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let shot = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(frame.width == shot.width && frame.height == shot.height,
                "framebuffer \(frame.width)×\(frame.height), screenshot \(shot.width)×\(shot.height)")
    }

    /// The device, its screen, and its input, on a known screen: Settings at its root.
    ///
    /// Launched WARM — brought to the front, not killed and relaunched — unless `cold`: an
    /// iPad takes a cold launch's Home as part of the launch now and then, and a relaunch
    /// can restore whatever page Settings was last on. Cold is for a test that needs Settings
    /// out of whatever mode the last run left it in, such as a search. Two swipes back from the left edge then reach
    /// the root on a phone; a tablet's sidebar has no stack to go back through, and a swipe
    /// from its edge can move the sidebar itself.
    @MainActor
    private func onSettings(cold: Bool = false) async throws -> SimulatorInput {
        let (device, handle) = try await bootedDevice()
        let input = try SimulatorInput(device: handle)
        if cold {
            _ = await SimulatorControl.run(["simctl", "terminate", device.udid, "com.apple.Preferences"], timeout: 10)
        }
        try await SimulatorControl.launch("com.apple.Preferences", on: device.udid)
        _ = try await settled()
        if !device.isTablet {
            for _ in 0..<2 { try await back(input) }
        }
        return input
    }

    /// A swipe back from the left edge, and the screen once it has settled.
    @MainActor
    private func back(_ input: SimulatorInput) async throws {
        try await swipe(input, from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 0.8, y: 0.5))
        _ = try await settled()
    }

    @MainActor
    private func swipe(_ input: SimulatorInput, from start: CGPoint, to end: CGPoint,
                       edge: SimulatorInput.Edge = .none) async throws {
        input.touch(.down, at: start, from: edge)
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(17))
            let t = Double(step) / 20
            input.touch(.moved, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                        from: edge)
        }
        input.touch(.up, at: end, from: edge)
    }

    @Test("Home leaves an app for the home screen")
    @MainActor
    func home() async throws {
        let input = try await onSettings()
        let before = try await settled()
        await input.pressAndRelease(.home)
        let after = try await settled()
        let changed = Self.differingFraction(before, after)
        #expect(changed > 0.05, "only \(changed) of the screen changed after Home")
    }

    /// The home indicator: iOS reads a swipe up as Home only when the touch says it began
    /// at the bottom edge. Without the flag the same swipe scrolled Settings and stayed.
    @Test("a swipe up from the bottom edge leaves an app")
    @MainActor
    func swipeHome() async throws {
        let input = try await onSettings()
        let before = try await settled()
        try await swipe(input, from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.6), edge: .bottom)
        let after = try await settled()
        let changed = Self.differingFraction(before, after)
        #expect(changed > 0.05, "only \(changed) of the screen changed after a swipe up from the bottom")
    }

    @Test("a tap selects a row in Settings")
    @MainActor
    func tap() async throws {
        let input = try await onSettings(cold: true)
        let (device, _) = try await bootedDevice()
        // Two different rows down the leading edge, each tapped from the root and compared
        // with each other: on an iPad the sidebar, on an iPhone the list, where each row
        // opens its own page.
        var screens: [CGImage] = []
        for row in [CGPoint(x: 0.15, y: 0.42), CGPoint(x: 0.15, y: 0.55)] {
            input.touch(.down, at: row)
            try await Task.sleep(for: .milliseconds(80))
            input.touch(.up, at: row)
            screens.append(try await settled())
            if !device.isTablet { try await back(input) }
        }
        let changed = Self.differingFraction(screens[0], screens[1])
        #expect(changed > 0.05, "only \(changed) of the screen differs between tapping two rows")
        // Awaited: a Home still going down when the process exits is a Home held down on
        // the device, and the next run finds it deaf.
        await input.pressAndRelease(.home)
    }

    /// A drag: swiping down the home screen opens Spotlight, on a phone and a tablet alike.
    @Test("a drag down the home screen opens Spotlight")
    @MainActor
    func drag() async throws {
        let input = try await onSettings()
        await input.pressAndRelease(.home)
        let home = try await settled()
        try await swipe(input, from: CGPoint(x: 0.5, y: 0.35), to: CGPoint(x: 0.5, y: 0.65))
        let spotlight = try await settled()
        let opened = Self.differingFraction(home, spotlight)
        #expect(opened > 0.05, "only \(opened) of the screen changed after a swipe down")
        // Awaited: a Home still going down when the process exits is a Home held down on
        // the device, and the next run finds it deaf.
        await input.pressAndRelease(.home)
    }

    /// Keys, into Settings' own search field — top left on a tablet, at the bottom on a
    /// phone. Not Spotlight's: an iPad's Spotlight shows a caret and takes no hardware keys.
    @Test("typing searches Settings")
    @MainActor
    func typing() async throws {
        let input = try await onSettings()
        let (device, _) = try await bootedDevice()
        let field = device.isTablet ? CGPoint(x: 0.15, y: 0.091) : CGPoint(x: 0.5, y: 0.935)
        input.touch(.down, at: field)
        try await Task.sleep(for: .milliseconds(80))
        input.touch(.up, at: field)
        _ = try await settled()

        // Two searches, compared with each other rather than with an empty field: the field
        // may keep the last query. "Zq" (shifted, so the modifier path is covered) finds
        // nothing; two deletes and "gen" find General.
        input.modifier(0x38, down: true)                      // left shift
        try await type([(6, "z")], on: input)
        input.modifier(0x38, down: false)
        try await type([(12, "q")], on: input)
        let nothing = try await settled()
        try await type([(51, "\u{8}"), (51, "\u{8}"), (5, "g"), (14, "e"), (45, "n")], on: input)
        let general = try await settled()
        let searched = Self.differingFraction(nothing, general)
        // The results are a panel, not the screen: "No Results" against a list of rows.
        #expect(searched > 0.001, "only \(searched) of the screen changed between two searches")
        await input.pressAndRelease(.home)
    }

    @MainActor
    private func type(_ keys: [(UInt16, String)], on input: SimulatorInput) async throws {
        for (code, character) in keys {
            try await Task.sleep(for: .milliseconds(40))
            input.key(Self.key(code, character, .keyDown))
            try await Task.sleep(for: .milliseconds(40))
            input.key(Self.key(code, character, .keyUp))
        }
    }

    private static func key(_ code: UInt16, _ character: String, _ type: NSEvent.EventType) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: code)!
    }

    /// The screen once it has stopped moving: still for a full second — three frames a
    /// third of a second apart that agree — or whatever is there after ten seconds.
    ///
    /// A second, not a frame: right after an app comes to the front the system is still
    /// finishing its launch, and a press that lands then is sometimes taken as part of it.
    ///
    /// Stillness is watched on the framebuffer, which is quick to read; the picture returned
    /// is `simctl io screenshot`'s. These tests are about whether input ARRIVES, and read on
    /// the CPU straight after a change, the framebuffer now and then still holds the screen
    /// before it — which would read as ignored input. `display()` checks the framebuffer
    /// against the same screenshot on its own.
    @MainActor
    private func settled() async throws -> CGImage {
        let (device, handle) = try await bootedDevice()
        try await Task.sleep(for: .milliseconds(500))
        var last = try #require(SimulatorDisplay.find(for: handle)?.snapshot())
        var still = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(330))
            let next = try #require(SimulatorDisplay.find(for: handle)?.snapshot())
            still = Self.differingFraction(last, next) < 0.002 ? still + 1 : 0
            last = next
            if still >= 3 { break }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ultra-live-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await SimulatorControl.screenshot(device.udid, to: file)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
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
