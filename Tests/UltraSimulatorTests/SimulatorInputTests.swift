import AppKit
import Testing
@testable import UltraSimulator

/// The parts of the private-API bridge that can be judged without a device: which wire
/// format a message is in, where messages are addressed, which screen is the device's own,
/// and the modifier tables. The device itself is `SimulatorLiveTests`' business.
@Suite("Simulator input")
@MainActor
struct SimulatorInputTests {

    /// A zeroed message of `size` bytes with the header words set, as a builder returns it.
    private func message(size: Int, payload: UInt32, kind: UInt8) -> UnsafeMutableRawPointer {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        bytes.storeBytes(of: payload, toByteOffset: 0x18, as: UInt32.self)
        bytes.storeBytes(of: kind, toByteOffset: 0x1c, as: UInt8.self)
        return bytes
    }

    @Test("Xcode 27's single-touch message is recognised and sent as built")
    func modernTouch() {
        let built = message(size: 0x160, payload: 0xA0, kind: 2)
        defer { built.deallocate() }
        #expect(SimulatorInput.layout(of: built, allocated: 0x160) == .modern)
    }

    @Test("the older 0x90 payload is recognised as needing idb's envelope")
    func legacyTouch() {
        let built = message(size: 0x140, payload: 0x90, kind: 3)
        defer { built.deallocate() }
        #expect(SimulatorInput.layout(of: built, allocated: 0x140) == .legacy)
    }

    @Test("a message too short for the layout it claims is not sent")
    func truncated() {
        let short = message(size: 0x40, payload: 0xA0, kind: 2)
        defer { short.deallocate() }
        #expect(SimulatorInput.layout(of: short, allocated: 0x40) == .unknown)
        let tiny = message(size: 0x20, payload: 0x90, kind: 2)
        defer { tiny.deallocate() }
        #expect(SimulatorInput.layout(of: tiny, allocated: 0x20) == .unknown)
    }

    @Test("the newer format addresses every message to the screen; the older kept buttons apart")
    func addressing() {
        #expect(SimulatorInput.isScreenAddressed(payloadSize: 0xA0))
        #expect(!SimulatorInput.isScreenAddressed(payloadSize: 0x90))
    }

    @Test("the built-in screen is chosen over TV-out, by type, then by id")
    func primaryScreen() {
        typealias Screen = SimulatorDisplay.ScreenIdentity
        // Spelled out: a bare `.init(…)` inside `#expect` does not resolve to the screen.
        let lcd = Screen(type: 0, id: 1), tvOut = Screen(type: 1, id: 2)
        #expect(SimulatorDisplay.isPrimary(lcd))
        #expect(!SimulatorDisplay.isPrimary(tvOut))
        // The type decides when there is one, whatever the id says.
        #expect(!SimulatorDisplay.isPrimary(Screen(type: 1, id: 1)))
        #expect(SimulatorDisplay.isPrimary(Screen(type: nil, id: 1)))
        #expect(!SimulatorDisplay.isPrimary(Screen(type: nil, id: 2)))
        #expect(!SimulatorDisplay.isPrimary(nil))
    }

    @Test("every modifier key has a HID usage and a flag, and no other key does")
    func modifiers() {
        for code in SimulatorInput.modifierUsage.keys {
            #expect(SimulatorInput.modifierFlag(for: code) != nil, "key code \(code)")
        }
        #expect(SimulatorInput.modifierUsage[0x38] == 0xE1)                 // left shift
        #expect(SimulatorInput.modifierFlag(for: 0x38) == .shift)
        #expect(SimulatorInput.modifierFlag(for: 0x00) == nil)              // "a"
        #expect(SimulatorInput.modifierUsage[0x00] == nil)
    }
}
