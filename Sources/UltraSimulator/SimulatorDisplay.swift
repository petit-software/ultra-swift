import CoreGraphics
import Foundation
import IOSurface

/// A live view of one device's screen: the IOSurface CoreSimulator renders into, and a
/// callback for every damaged frame.
///
/// The device's IO ports include one conforming to `SimDisplayIOSurfaceRenderable`. Its
/// `framebufferSurface` is the actual framebuffer — the same surface the simulator's own
/// compositor writes — so showing it is a matter of pointing a layer at it, no copy and no
/// permission prompt. The surface is REPLACED rather than resized when the device rotates
/// or changes scale, which is what the surfaces-change callback is for.
@MainActor
public final class SimulatorDisplay {

    /// The framebuffer, or nil until the device's display port is up.
    public private(set) var surface: IOSurface?
    /// The masked variant, with the corner and notch mask applied. Nil on runtimes without one.
    public private(set) var maskedSurface: IOSurface?
    /// Pixels, the size of the surface.
    public private(set) var pixelSize: CGSize = .zero
    /// Degrees, clockwise; 0 is portrait.
    public private(set) var angle: Double = 0

    /// The screen changed. Called on the main actor for every damaged frame and every
    /// surface swap; the receiver re-sets its layer contents.
    public var onFrame: (() -> Void)?

    private let port: AnyObject
    private let uuid = UUID()
    private var registered = false

    /// The display port of a device's own screen, or nil when it has none — a device that
    /// is not booted has no ports at all.
    ///
    /// A device has more than one: an iPad also carries a TV-out screen, and a CarPlay one
    /// can be attached. The port list is not ordered by importance, so the built-in screen is
    /// picked by what it says about itself — see `isPrimary` — and only a runtime too old
    /// to say anything falls back to the first.
    public static func find(for device: AnyObject) -> SimulatorDisplay? {
        guard let io = ObjC.object(device, "io"),
              let ports = ObjC.object(io, "ioPorts") as? [AnyObject],
              let renderable = NSProtocolFromString("SimDisplayIOSurfaceRenderable") else { return nil }
        let displays = ports.compactMap { port -> AnyObject? in
            guard let descriptor = ObjC.object(port, "descriptor"), descriptor.conforms(to: renderable) else { return nil }
            return descriptor
        }
        let primary = displays.first { isPrimary(screen(of: $0)) } ?? displays.first
        return primary.map(SimulatorDisplay.init(port:))
    }

    /// What a screen port says about itself. Either may be nil on a runtime that does not
    /// say.
    struct ScreenIdentity: Equatable {
        var type: UInt64?
        var id: UInt32?
    }

    /// Whether a screen is the device's built-in one: `screenType` 0 (TV-out is 1), or,
    /// failing that, screen id 1.
    static func isPrimary(_ screen: ScreenIdentity?) -> Bool {
        guard let screen else { return false }
        if let type = screen.type { return type == 0 }
        return screen.id == 1
    }

    /// A screen port's type and id, through `SimScreenProperties`' own typed getters.
    ///
    /// The properties arrive as an immutable proxy that answers each getter from a table.
    /// The table itself is NOT walked: some of its entries are not objects, and retaining
    /// one traps under pointer authentication. Nil for a port that is not a `SimScreen`.
    private static func screen(of descriptor: AnyObject) -> ScreenIdentity? {
        guard let screen = NSProtocolFromString("SimScreen"), descriptor.conforms(to: screen),
              let properties = ObjC.object(descriptor, "screenProperties") else { return nil }
        var identity = ScreenIdentity()
        if ObjC.responds(properties, "screenType") {
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt64
            identity.type = ObjC.msgSend(Getter.self)(properties, NSSelectorFromString("screenType"))
        }
        if ObjC.responds(properties, "screenID") {
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
            identity.id = ObjC.msgSend(Getter.self)(properties, NSSelectorFromString("screenID"))
        }
        return identity
    }

    private init(port: AnyObject) {
        self.port = port
        readSurfaces()
    }

    deinit {
        // Unregister on the port's own terms. A callback outliving its display would land
        // on a freed object; the port keeps the block until told otherwise.
        MainActor.assumeIsolated { stop() }
    }

    /// Ask for frames. Idempotent.
    public func start() {
        guard !registered else { return }
        registered = true
        let uuid = self.uuid as NSUUID
        // Blocks with NO parameters on purpose: the port calls the damage callback with an
        // array of rectangles and the surfaces callback with the new surface, but this
        // redraws the whole layer either way, and a block that declares fewer parameters
        // than it is handed is safe under the calling convention where one that declares
        // the wrong ones is not.
        let damaged: @convention(block) () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.frameChanged() }
        }
        let swapped: @convention(block) () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.surfacesChanged() }
        }
        let rotated: @convention(block) () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.surfacesChanged() }
        }
        typealias Register = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
        if ObjC.responds(port, "registerCallbackWithUUID:damageRectanglesCallback:") {
            ObjC.msgSend(Register.self)(port, NSSelectorFromString("registerCallbackWithUUID:damageRectanglesCallback:"),
                                        uuid, damaged as AnyObject)
        }
        if ObjC.responds(port, "registerCallbackWithUUID:ioSurfacesChangeCallback:") {
            ObjC.msgSend(Register.self)(port, NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:"),
                                        uuid, swapped as AnyObject)
        }
        if ObjC.responds(port, "registerCallbackWithUUID:rotationAngleCallback:") {
            ObjC.msgSend(Register.self)(port, NSSelectorFromString("registerCallbackWithUUID:rotationAngleCallback:"),
                                        uuid, rotated as AnyObject)
        }
    }

    public func stop() {
        guard registered else { return }
        registered = false
        let uuid = self.uuid as NSUUID
        typealias Unregister = @convention(c) (AnyObject, Selector, NSUUID) -> Void
        for selector in ["unregisterDamageRectanglesCallbackWithUUID:",
                         "unregisterIOSurfacesChangeCallbackWithUUID:",
                         "unregisterRotationAngleCallbackWithUUID:"]
        where ObjC.responds(port, selector) {
            ObjC.msgSend(Unregister.self)(port, NSSelectorFromString(selector), uuid)
        }
    }

    /// Read the surfaces again, for a holder that suspects it missed a swap. Returns
    /// whether anything changed, and tells `onFrame` when it did.
    @discardableResult
    public func refresh() -> Bool {
        // By id: a read hands back a new wrapper for the same surface.
        func ids() -> [IOSurfaceID?] { [surface, maskedSurface].map { $0.map(IOSurfaceGetID) } }
        let before = ids()
        readSurfaces()
        guard ids() != before else { return false }
        onFrame?()
        return true
    }

    private func frameChanged() {
        onFrame?()
    }

    private func surfacesChanged() {
        readSurfaces()
        onFrame?()
    }

    private func readSurfaces() {
        surface = ObjC.object(port, "framebufferSurface") as? IOSurface
        maskedSurface = ObjC.object(port, "maskedFramebufferSurface") as? IOSurface
        if let surface {
            pixelSize = CGSize(width: surface.width, height: surface.height)
        }
        if ObjC.responds(port, "displayAngle") {
            typealias Angle = @convention(c) (AnyObject, Selector) -> Double
            angle = ObjC.msgSend(Angle.self)(port, NSSelectorFromString("displayAngle"))
        }
    }

    /// The current frame as an image, for a screenshot. A copy: the surface keeps moving.
    ///
    /// The surfaces are read afresh first. The device REPLACES its framebuffer — on a
    /// relaunch, a lock, a rotation — and a picture taken from the one held since the
    /// last callback can be of a screen that is no longer there.
    public func snapshot() -> CGImage? {
        readSurfaces()
        guard let surface = maskedSurface ?? surface else { return nil }
        let context = CIContext()
        let image = CIImage(ioSurface: surface)
        return context.createCGImage(image, from: image.extent)
    }
}

import CoreImage
