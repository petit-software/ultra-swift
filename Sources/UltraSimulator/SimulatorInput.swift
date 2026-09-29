import AppKit
import Foundation

/// Touches, hardware buttons and keys, delivered to one device.
///
/// The transport is SimulatorKit's `SimDeviceLegacyHIDClient`, the same object Xcode's
/// embedded simulator and Meta's idb send through. The messages are built by SimulatorKit's
/// own exported C functions — `IndigoHIDMessageForMouseNSEvent`, `IndigoHIDMessageForButton`,
/// `IndigoHIDMessageForKeyboardNSEvent`, `IndigoHIDMessageForKeyboardArbitrary` — so this file does not know the wire format,
/// with one exception described at `touchMessage`: an older SimulatorKit's touch has to be
/// re-enveloped, and which kind this Xcode builds is read off the message's header.
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

    /// Where a touch started, for the system gestures that begin at the screen's edge.
    ///
    /// The number is SimulatorKit's `IndigoHIDEdge`, which the touch builder turns into the
    /// digitizer's edge flags. Only the bottom is sent: iOS needs it to read a swipe up as
    /// Home, the app switcher or unlock, and ignores the swipe without it. A swipe from the
    /// top or the left works from the position alone, and was found to with every value.
    public enum Edge: UInt32, Sendable {
        case none = 0
        case bottom = 3
    }

    public enum Button {
        case home, lock
        /// `ButtonEventSource*` in SimulatorKit's terms.
        ///
        /// No Siri: idb's Siri source, 0x400002, sent to an Xcode 27 device brings its home
        /// screen down — every app launch after it failed with "the system shell probably
        /// crashed" until SpringBoard came back.
        var source: Int32 {
            switch self {
            case .home: 0x0
            case .lock: 0x1
            }
        }
    }

    private typealias MessageForMouseNSEvent = @convention(c) (
        UnsafeMutablePointer<CGPoint>?, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias MessageForButton = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias MessageForKeyboard = @convention(c) (UInt32, Int32) -> UnsafeMutableRawPointer?
    private typealias MessageForKeyEvent = @convention(c) (NSEvent) -> UnsafeMutableRawPointer?

    private let client: AnyObject
    private let mouse: MessageForMouseNSEvent
    private let button: MessageForButton
    private let keyboard: MessageForKeyboard
    private let keyEvent: MessageForKeyEvent
    private let queue = DispatchQueue(label: "com.ultra.simulator-hid")

    /// The HID service of the device's screen — its digitizer — and the one older
    /// SimulatorKit took hardware buttons on. Constants of the protocol; see
    /// `isScreenAddressed` for which a message goes to.
    private static let screenTarget: UInt32 = 0x32
    private static let legacyButtonTarget: Int32 = 0x33
    private static let opDown: Int32 = 1
    private static let opUp: Int32 = 2

    public init(device: AnyObject) throws {
        let frameworks = SimulatorFrameworks.shared
        client = try Self.connect(to: device)
        guard let mouseSymbol = frameworks.symbol("IndigoHIDMessageForMouseNSEvent") else {
            throw Failure.noBuilder("IndigoHIDMessageForMouseNSEvent")
        }
        guard let buttonSymbol = frameworks.symbol("IndigoHIDMessageForButton") else {
            throw Failure.noBuilder("IndigoHIDMessageForButton")
        }
        guard let keySymbol = frameworks.symbol("IndigoHIDMessageForKeyboardArbitrary") else {
            throw Failure.noBuilder("IndigoHIDMessageForKeyboardArbitrary")
        }
        guard let keyEventSymbol = frameworks.symbol("IndigoHIDMessageForKeyboardNSEvent") else {
            throw Failure.noBuilder("IndigoHIDMessageForKeyboardNSEvent")
        }
        mouse = unsafeBitCast(mouseSymbol, to: MessageForMouseNSEvent.self)
        button = unsafeBitCast(buttonSymbol, to: MessageForButton.self)
        keyboard = unsafeBitCast(keySymbol, to: MessageForKeyboard.self)
        keyEvent = unsafeBitCast(keyEventSymbol, to: MessageForKeyEvent.self)
        prime()
    }

    /// Start clean: one message that changes nothing, then Home and Lock let go.
    ///
    /// The first message a process sends is ignored: measured on an iPad and an iPhone, the
    /// first Home press after launch did nothing and every one after it worked. So the
    /// first message is the right Option key let go, when it was never held.
    ///
    /// Then Home and Lock, because a button left held on the device outlives whoever held
    /// it — a pane closed mid-press, a crash — and a held button swallows every later press
    /// of it. Letting go of one that is not held does nothing, so every new connection — a
    /// device chosen, booted, reconnected — does it.
    private func prime() {
        if let usage = Self.modifierUsage[0x3D], let message = keyboard(usage, Self.opUp) {
            send(addressed(message))
        }
        for hardware in [Button.home, .lock] {
            if let lift = buttonMessage(hardware, op: Self.opUp) { send(lift) }
        }
    }

    /// A new connection to the device's HID service.
    private static func connect(to device: AnyObject) throws -> AnyObject {
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
        return made
    }

    // MARK: - Verbs

    /// A finger at `ratio`, where (0, 0) is the top-left of the screen and (1, 1) the
    /// bottom-right, whatever the device's size or scale.
    ///
    /// Every phase of one gesture carries the edge it started from.
    public func touch(_ phase: Phase, at ratio: CGPoint, from edge: Edge = .none) {
        guard let message = touchMessage(phase: phase, ratio: ratio, edge: edge.rawValue) else { return }
        send(message)
    }

    /// A hardware button pressed and let go, held for a tenth of a second as a finger
    /// would hold it.
    ///
    /// Both halves are built before either is sent, and the lift is kept until it has
    /// gone: a button left down on the device swallows every press, touch and key after it
    /// — the device looks dead until something lets the button go. `releaseAll` sends a
    /// pending lift at once, for a pane closing mid-press.
    public func press(_ hardware: Button) {
        Task { await pressAndRelease(hardware) }
    }

    /// `press`, returning once the button is back up — for a caller about to go away, such
    /// as a process that exits right after.
    public func pressAndRelease(_ hardware: Button) async {
        guard let down = buttonMessage(hardware, op: Self.opDown) else { return }
        guard let up = buttonMessage(hardware, op: Self.opUp) else { free(down); return }
        send(down)
        pendingLifts.append(up)
        try? await Task.sleep(for: .milliseconds(100))
        // Still pending unless `releaseAll` sent it meanwhile.
        if let index = pendingLifts.firstIndex(of: up) {
            pendingLifts.remove(at: index)
            send(up)
        }
    }

    /// Button lifts built and not yet sent.
    private var pendingLifts: [UnsafeMutableRawPointer] = []

    /// A key down or up, as AppKit delivered it. SimulatorKit's own builder turns the Mac
    /// key code into the HID usage the device reads, with the same table Simulator uses.
    ///
    /// An auto-repeat is not sent: the device repeats a held key itself, as Xcode leaves it to.
    public func key(_ event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp, !event.isARepeat,
              let message = keyEvent(event) else { return }
        if event.type == .keyDown { heldKeys.insert(event.keyCode) } else { heldKeys.remove(event.keyCode) }
        send(addressed(message))
    }

    /// Keys and modifiers this side has put down and not yet lifted.
    private var heldKeys: Set<UInt16> = []
    private var heldModifiers: Set<UInt16> = []

    /// Lift everything still held: keys, modifiers, and a button mid-press. For when the
    /// screen loses the keyboard or the pane lets go: the key-up goes to whatever view has
    /// it next, and the device would otherwise type the key, hold Shift, or hold Home until
    /// the next press of the same one.
    public func releaseAll() {
        for code in heldKeys {
            guard let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code),
                  let message = keyEvent(up) else { continue }
            send(addressed(message))
        }
        heldKeys.removeAll()
        for code in heldModifiers { modifier(code, down: false) }
        let lifts = pendingLifts
        pendingLifts.removeAll()
        lifts.forEach(send)
    }

    /// A modifier went down or up. AppKit reports those as `flagsChanged`, which the event
    /// builder above reads as a key up; they are sent by their HID usage instead, so a
    /// shifted letter arrives shifted.
    public func modifier(_ keyCode: UInt16, down: Bool) {
        guard let usage = Self.modifierUsage[keyCode],
              let message = keyboard(usage, down ? Self.opDown : Self.opUp) else { return }
        if down { heldModifiers.insert(keyCode) } else { heldModifiers.remove(keyCode) }
        send(addressed(message))
    }

    /// Mac virtual key code → HID keyboard usage, for the keys that arrive as `flagsChanged`.
    /// The key codes are `<HIToolbox/Events.h>`'s; the usages the USB HID tables'.
    static let modifierUsage: [UInt16: UInt32] = [
        0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3,   // left control, shift, option, command
        0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7,   // right control, shift, option, command
        0x39: 0x39,                                       // caps lock
    ]

    /// The modifier flag a modifier key sets, so a `flagsChanged` can tell down from up.
    public static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x3B, 0x3E: .control
        case 0x38, 0x3C: .shift
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        case 0x39: .capsLock
        default: nil
        }
    }

    // MARK: - Messages

    private func buttonMessage(_ hardware: Button, op: Int32) -> UnsafeMutableRawPointer? {
        button(hardware.source, op, isScreenAddressed ? Int32(Self.screenTarget) : Self.legacyButtonTarget)
    }

    /// Whether this SimulatorKit addresses EVERY message — touches, buttons, keys — to the
    /// screen's own HID service, 0x32.
    ///
    /// Older SimulatorKit took hardware buttons on their own service, 0x33, as idb sends
    /// them, and keys on the one the keyboard builder writes, 0x64. The SimulatorKit that
    /// grew the payload to 0xA0 bytes (Xcode 27) takes all of it on 0x32 and drops the rest
    /// without a word: Home did nothing, typing did nothing. So the builder is asked once,
    /// and the layout it answers in decides.
    private lazy var isScreenAddressed: Bool = {
        guard let probe = button(Button.home.source, Self.opUp, Self.legacyButtonTarget) else { return false }
        defer { free(probe) }
        return Self.isScreenAddressed(payloadSize: probe.load(fromByteOffset: 0x18, as: UInt32.self))
    }()

    static func isScreenAddressed(payloadSize: UInt32) -> Bool { payloadSize != 0x90 }

    /// A keyboard message pointed at the screen's service when this SimulatorKit wants that;
    /// the target is the word at 0x38, where the button builder puts its own.
    private func addressed(_ message: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
        if isScreenAddressed { message.storeBytes(of: Self.screenTarget, toByteOffset: 0x38, as: UInt32.self) }
        return message
    }

    /// A single-finger touch, in whichever of SimulatorKit's two layouts this Xcode speaks.
    ///
    /// Modern SimulatorKit (Xcode 27 on) builds the whole message itself: a single-touch
    /// envelope with the contact and its repeated copy, payloads 0xA0 long, and a real
    /// "moved" phase for a drag. It is sent exactly as built. The builder also THROTTLES:
    /// a drag within 16ms of the last message it built comes back nil, and is skipped —
    /// the next one, or the lift, carries the finger to where it is.
    ///
    /// Older SimulatorKit emitted a multi-touch message with 0x90 payloads, which the guest
    /// treats differently from a plain tap, and declined anything but a down or an up. For
    /// that one the contact is lifted out into a single-touch envelope exactly as idb does
    /// (`SimulatorIndigoHID.touchMessage`), and a finger that moves is another DOWN at the
    /// new point, the way idb swipes. Offsets are those of the packed structs in idb's
    /// `Indigo.h`: the payload at 0x20, the digitizer contact at 0x30 and 0x70 long, and a
    /// second copy of the payload at 0xB0 marked as the repeated contact.
    ///
    /// Sending the old envelope to the new guest is silently dropped — every click did
    /// nothing — so the layout is read off what the builder returns, never assumed.
    private func touchMessage(phase: Phase, ratio: CGPoint, edge: UInt32) -> UnsafeMutableRawPointer? {
        if phase == .moved, layout == .legacy {
            return legacyTouch(built(.leftMouseDown, at: ratio, edge: edge), ratio: ratio)
        }
        let eventType: NSEvent.EventType = switch phase {
        case .down: .leftMouseDown
        case .moved: .leftMouseDragged
        case .up: .leftMouseUp
        }
        guard let source = built(eventType, at: ratio, edge: edge) else { return nil }
        let detected = Self.layout(of: source)
        layout = detected
        switch detected {
        case .modern: return source
        case .legacy: return legacyTouch(source, ratio: ratio)
        case .unknown:
            free(source)
            return nil
        }
    }

    /// What the builder makes of a mouse event at a ratio. A unit size makes its own
    /// normalisation the identity: the point is already a ratio.
    private func built(_ eventType: NSEvent.EventType, at ratio: CGPoint, edge: UInt32) -> UnsafeMutableRawPointer? {
        var point = ratio
        return mouse(&point, nil, Self.screenTarget, UInt(eventType.rawValue), CGSize(width: 1, height: 1), edge)
    }

    /// The layouts a touch message comes in. Read from the header: the payload's length
    /// at 0x18 and the message kind at 0x1C, 2 for a single touch.
    enum TouchLayout: Equatable { case modern, legacy, unknown }

    /// Learnt from the first touch the builder makes, so a legacy drag can be sent as the
    /// down it has to be before the builder is asked for a drag it would decline.
    private var layout: TouchLayout?

    static func layout(of message: UnsafeRawPointer, allocated: Int? = nil) -> TouchLayout {
        let size = allocated ?? malloc_size(message)
        guard size >= 0x20 else { return .unknown }
        let payload = Int(message.load(fromByteOffset: 0x18, as: UInt32.self))
        let kind = message.load(fromByteOffset: 0x1c, as: UInt8.self)
        if payload == 0x90, size >= 0x30 + 0x70 { return .legacy }
        if kind == 2, payload >= 0x90, size >= 0x20 + payload * 2 { return .modern }
        return .unknown
    }

    private func legacyTouch(_ source: UnsafeMutableRawPointer?, ratio: CGPoint) -> UnsafeMutableRawPointer? {
        guard let source else { return nil }
        defer { free(source) }
        source.storeBytes(of: Double(ratio.x), toByteOffset: 0x3c, as: Double.self)
        source.storeBytes(of: Double(ratio.y), toByteOffset: 0x44, as: Double.self)

        let payloadSize = 0x90, touchSize = 0x70, headerSize = 0x20
        guard let message = calloc(1, headerSize + payloadSize * 2) else { return nil }
        message.storeBytes(of: UInt32(payloadSize), toByteOffset: 0x18, as: UInt32.self)
        message.storeBytes(of: UInt8(2), toByteOffset: 0x1c, as: UInt8.self)          // single touch
        message.storeBytes(of: UInt32(0xB), toByteOffset: 0x20, as: UInt32.self)       // digitizer event
        message.storeBytes(of: mach_absolute_time(), toByteOffset: 0x24, as: UInt64.self)
        message.advanced(by: 0x30).copyMemory(from: source.advanced(by: 0x30), byteCount: touchSize)
        message.advanced(by: headerSize + payloadSize)
            .copyMemory(from: message.advanced(by: headerSize), byteCount: payloadSize)
        message.storeBytes(of: UInt32(1), toByteOffset: headerSize + payloadSize + 0x10, as: UInt32.self)
        message.storeBytes(of: UInt32(2), toByteOffset: headerSize + payloadSize + 0x14, as: UInt32.self)
        return message
    }

    /// Hand a message to the client, which frees it once delivered. Every message here is
    /// malloc'd — by SimulatorKit's builders or by `calloc` above — so `freeWhenDone` is
    /// the right owner and nothing is copied.
    private func send(_ message: UnsafeMutableRawPointer) {
        let completion: @convention(block) (NSError?) -> Void = { _ in }
        typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject) -> Void
        ObjC.msgSend(Send.self)(client, NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:"),
                                message, true, queue, completion as AnyObject)
    }
}
