import AppKit
import Foundation

/// Touches, hardware buttons and keys, delivered to one device.
///
/// The transport is SimulatorKit's `SimDeviceLegacyHIDClient`, the same object Xcode's
/// embedded simulator and Meta's idb send through. The messages are built by SimulatorKit's
/// own exported C functions — `IndigoHIDMessageForMouseNSEvent`, `IndigoHIDMessageForButton`,
/// `IndigoHIDMessageForKeyboardArbitrary` — so this file does not know the wire format,
/// with one exception described at `touchMessage`.
@MainActor
public final class SimulatorInput {

    public enum Failure: Error, CustomStringConvertible {
        case noClient(String)
        case noBuilder(String)

        public var description: String {
            switch self {
            case .noClient(let why): "The simulator refused a touch connection: \(why)"
            case .noBuilder(let name): "This Xcode's SimulatorKit has no \(name)"
            }
        }
    }

    public enum Phase { case down, moved, up }

    public enum Button {
        case home, lock, siri
        /// `ButtonEventSource*` in SimulatorKit's terms.
        var source: Int32 {
            switch self {
            case .home: 0x0
            case .lock: 0x1
            case .siri: 0x400002
            }
        }
    }

    private typealias MessageForMouseNSEvent = @convention(c) (
        UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias MessageForButton = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias MessageForKeyboard = @convention(c) (UInt32, Int32) -> UnsafeMutableRawPointer?

    private let client: AnyObject
    private let mouse: MessageForMouseNSEvent
    private let button: MessageForButton
    private let keyboard: MessageForKeyboard
    private let queue = DispatchQueue(label: "com.ultra.simulator-hid")

    /// The HID service the digitizer listens on, and the one the sourced button builder
    /// addresses. Both are constants of the protocol.
    private static let digitizerTarget: UInt32 = 0x32
    private static let hardwareTarget: Int32 = 0x33
    private static let opDown: Int32 = 1
    private static let opUp: Int32 = 2

    public init(device: AnyObject) throws {
        let frameworks = SimulatorFrameworks.shared
        guard let clientClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
                ?? NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") else {
            throw Failure.noClient("no SimDeviceLegacyHIDClient in this Xcode")
        }
        guard let allocated = ObjC.object(clientClass, "alloc") else {
            throw Failure.noClient("alloc failed")
        }
        var error: NSError?
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let made: AnyObject? = withUnsafeMutablePointer(to: &error) { pointer in
            ObjC.msgSend(Init.self)(allocated, NSSelectorFromString("initWithDevice:error:"), device, pointer)
        }
        guard let made else {
            throw Failure.noClient(error?.localizedDescription ?? "the device did not answer")
        }
        client = made
        guard let mouseSymbol = frameworks.symbol("IndigoHIDMessageForMouseNSEvent") else {
            throw Failure.noBuilder("IndigoHIDMessageForMouseNSEvent")
        }
        guard let buttonSymbol = frameworks.symbol("IndigoHIDMessageForButton") else {
            throw Failure.noBuilder("IndigoHIDMessageForButton")
        }
        guard let keySymbol = frameworks.symbol("IndigoHIDMessageForKeyboardArbitrary") else {
            throw Failure.noBuilder("IndigoHIDMessageForKeyboardArbitrary")
        }
        mouse = unsafeBitCast(mouseSymbol, to: MessageForMouseNSEvent.self)
        button = unsafeBitCast(buttonSymbol, to: MessageForButton.self)
        keyboard = unsafeBitCast(keySymbol, to: MessageForKeyboard.self)
    }

    // MARK: - Verbs

    /// A finger at `ratio`, where (0, 0) is the top-left of the screen and (1, 1) the
    /// bottom-right, whatever the device's size or scale.
    public func touch(_ phase: Phase, at ratio: CGPoint) {
        guard let message = touchMessage(phase: phase, ratio: ratio) else { return }
        send(message)
    }

    public func press(_ hardware: Button) {
        guard let down = buttonMessage(hardware, op: Self.opDown) else { return }
        send(down)
        guard let up = buttonMessage(hardware, op: Self.opUp) else { return }
        send(up)
    }

    /// A key, by the hardware-independent code in `<HIToolbox/Events.h>` — the one
    /// `NSEvent.keyCode` carries.
    public func key(_ keyCode: UInt16, down: Bool) {
        guard let message = keyboard(UInt32(keyCode), down ? Self.opDown : Self.opUp) else { return }
        send(Message(bytes: message, count: malloc_size(message)))
    }

    // MARK: - Messages

    private struct Message {
        var bytes: UnsafeMutableRawPointer
        var count: Int
    }

    private func buttonMessage(_ hardware: Button, op: Int32) -> Message? {
        guard let message = button(hardware.source, op, Self.hardwareTarget) else { return nil }
        return Message(bytes: message, count: malloc_size(message))
    }

    /// A single-finger touch.
    ///
    /// The one place the wire format is known here, and it is known because SimulatorKit
    /// has no single-touch builder: `IndigoHIDMessageForMouseNSEvent` always emits a
    /// multi-touch message, which the guest treats differently from a plain tap. So the
    /// contact it builds is lifted out and put in a single-touch envelope, exactly as idb
    /// does (`SimulatorIndigoHID.touchMessage`). Offsets are those of the packed structs in
    /// idb's `Indigo.h`: the payload at 0x20, the digitizer contact at 0x30 and 0x70 long,
    /// and a second copy of the payload at 0xB0 marked as the repeated contact.
    ///
    /// Nil when the builder declines, which it does for any event but a mouse down or up —
    /// hence a finger that moves is sent as another DOWN at the new point, the way idb
    /// swipes. Writing into what it returned without looking was a crash on every drag.
    private func touchMessage(phase: Phase, ratio: CGPoint) -> Message? {
        var point = ratio
        let eventType: UInt = switch phase {
        case .down, .moved: UInt(NSEvent.EventType.leftMouseDown.rawValue)
        case .up: UInt(NSEvent.EventType.leftMouseUp.rawValue)
        }
        // A unit size makes the builder's own normalisation the identity: the point is
        // already a ratio.
        guard let source = mouse(&point, nil, Self.digitizerTarget, eventType, CGSize(width: 1, height: 1), 0),
              malloc_size(source) >= 0x30 + 0x70 else { return nil }
        defer { free(source) }
        source.storeBytes(of: Double(ratio.x), toByteOffset: 0x3c, as: Double.self)
        source.storeBytes(of: Double(ratio.y), toByteOffset: 0x44, as: Double.self)

        let payloadSize = 0x90, touchSize = 0x70, headerSize = 0x20
        let count = headerSize + payloadSize * 2
        guard let message = calloc(1, count) else { return nil }
        message.storeBytes(of: UInt32(payloadSize), toByteOffset: 0x18, as: UInt32.self)
        message.storeBytes(of: UInt8(2), toByteOffset: 0x1c, as: UInt8.self)          // single touch
        message.storeBytes(of: UInt32(0xB), toByteOffset: 0x20, as: UInt32.self)       // digitizer event
        message.storeBytes(of: mach_absolute_time(), toByteOffset: 0x24, as: UInt64.self)
        message.advanced(by: 0x30).copyMemory(from: source.advanced(by: 0x30), byteCount: touchSize)
        message.advanced(by: headerSize + payloadSize)
            .copyMemory(from: message.advanced(by: headerSize), byteCount: payloadSize)
        message.storeBytes(of: UInt32(1), toByteOffset: headerSize + payloadSize + 0x10, as: UInt32.self)
        message.storeBytes(of: UInt32(2), toByteOffset: headerSize + payloadSize + 0x14, as: UInt32.self)
        return Message(bytes: message, count: count)
    }

    /// Hand a message to the client, which frees it once delivered. Every message here is
    /// malloc'd — by SimulatorKit's builders or by `calloc` above — so `freeWhenDone` is
    /// the right owner and nothing is copied.
    private func send(_ message: Message) {
        let completion: @convention(block) (NSError?) -> Void = { _ in }
        typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject) -> Void
        ObjC.msgSend(Send.self)(client, NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:"),
                                message.bytes, true, queue, completion as AnyObject)
    }
}
