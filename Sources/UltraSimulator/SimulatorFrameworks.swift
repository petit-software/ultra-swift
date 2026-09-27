import Foundation
import ObjectiveC

/// Xcode's CoreSimulator and SimulatorKit, loaded at runtime and driven through the
/// Objective-C runtime.
///
/// PRIVATE API, and the only private API in the app. It exists for two things `simctl`
/// cannot do: hand over the device's live framebuffer, and deliver a touch. Xcode's own
/// Previews embed a device the same way — `IDEPlaygroundSimulator` links SimulatorKit — and
/// Meta's idb drives devices through the same classes, so the surface has stayed stable
/// across many Xcodes. It is still Apple's to change, which is why:
///
/// - nothing is LINKED. Both frameworks are `dlopen`ed by path, every class is looked up by
///   name, and every selector is checked with `responds(to:)` before it is sent. A missing
///   piece is an error the pane can show, not a crash at launch on a machine without Xcode;
/// - both frameworks are signed by Apple, which the hardened runtime's library validation
///   permits. No entitlement is needed and none is added;
/// - the one place this is used is behind `SimulatorSession`, whose every other verb goes
///   through `simctl`. If the load fails, the pane still boots, lists and screenshots — it
///   just cannot show the screen live.
@MainActor
public final class SimulatorFrameworks {

    public static let shared = SimulatorFrameworks()

    public enum Failure: Error, CustomStringConvertible {
        case noXcode
        case couldNotLoad(String)
        case missing(String)
        case noSuchDevice(String)

        public var description: String {
            switch self {
            case .noXcode: "Xcode is not installed, so there are no simulators"
            case .couldNotLoad(let what): "Could not load \(what)"
            case .missing(let what): "This Xcode's simulator framework has no \(what)"
            case .noSuchDevice(let udid): "No simulator with the id \(udid)"
            }
        }
    }

    private var coreSimulator: UnsafeMutableRawPointer?
    private var simulatorKit: UnsafeMutableRawPointer?
    private var context: AnyObject?
    private var loadError: Failure?

    private init() {}

    /// Whether the live path is available. Loads on first ask.
    public var isAvailable: Bool {
        (try? load()) != nil
    }

    public var error: Failure? {
        _ = isAvailable
        return loadError
    }

    /// The `SimServiceContext` for the selected Xcode.
    @discardableResult
    func load() throws -> AnyObject {
        if let context { return context }
        if let loadError { throw loadError }
        do {
            guard let developer = SimulatorControl.developerDirectory else { throw Failure.noXcode }
            let core = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
            let kit = URL(fileURLWithPath: developer)
                .deletingLastPathComponent()   // Contents
                .appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path
            guard let coreHandle = dlopen(core, RTLD_NOW) else {
                throw Failure.couldNotLoad("CoreSimulator: \(dlerrorText())")
            }
            coreSimulator = coreHandle
            guard let kitHandle = dlopen(kit, RTLD_NOW) else {
                throw Failure.couldNotLoad("SimulatorKit: \(dlerrorText())")
            }
            simulatorKit = kitHandle

            guard let contextClass = NSClassFromString("SimServiceContext") else {
                throw Failure.missing("SimServiceContext")
            }
            let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
            guard contextClass.responds(to: selector) else {
                throw Failure.missing("sharedServiceContextForDeveloperDir:")
            }
            var error: NSError?
            typealias Shared = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>) -> AnyObject?
            let made: AnyObject? = withUnsafeMutablePointer(to: &error) { pointer in
                ObjC.msgSend(Shared.self)(contextClass, selector, developer as NSString, pointer)
            }
            guard let made else {
                throw Failure.couldNotLoad("the simulator service: \(error?.localizedDescription ?? "no context")")
            }
            context = made
            return made
        } catch let failure as Failure {
            loadError = failure
            throw failure
        }
    }

    /// The SimulatorKit symbol of this name, for the C functions that build HID messages.
    func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let simulatorKit else { return nil }
        return dlsym(simulatorKit, name)
    }

    /// The live `SimDevice` for a UDID, from the default device set.
    public func device(udid: String) throws -> AnyObject {
        let context = try load()
        var error: NSError?
        typealias DefaultSet = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let set: AnyObject? = withUnsafeMutablePointer(to: &error) { pointer in
            ObjC.msgSend(DefaultSet.self)(context, NSSelectorFromString("defaultDeviceSetWithError:"), pointer)
        }
        guard let set else {
            throw Failure.couldNotLoad("the device set: \(error?.localizedDescription ?? "none")")
        }
        guard let devices = ObjC.object(set, "devices") as? [AnyObject] else {
            throw Failure.missing("devices")
        }
        let wanted = udid.uppercased()
        for device in devices {
            if let id = ObjC.object(device, "UDID") as? UUID, id.uuidString == wanted {
                return device
            }
        }
        throw Failure.noSuchDevice(udid)
    }

    /// CoreSimulator's own state number for a device: 1 shutdown, 2 booting, 3 booted,
    /// 4 shutting down.
    public func state(of device: AnyObject) -> Int {
        typealias State = @convention(c) (AnyObject, Selector) -> Int64
        return Int(ObjC.msgSend(State.self)(device, NSSelectorFromString("state")))
    }

    private func dlerrorText() -> String {
        dlerror().map { String(cString: $0) } ?? "unknown error"
    }
}

/// Typed `objc_msgSend`, for selectors whose return is not an object.
///
/// `perform(_:)` covers object returns and object arguments, which is most of it. A CGSize,
/// a double, a BOOL, a raw pointer, or a block argument needs the real calling convention,
/// and casting `objc_msgSend` to the exact signature is the supported way to get it. It goes
/// through message forwarding too, which matters: CoreSimulator hands out proxy objects
/// (`ROCKRemoteProxy`) for the device's IO ports, and a method looked up on the proxy's
/// class would not be found — the proxy forwards it.
///
/// Every call site spells its signature as a `@convention(c)` typealias: the compiler needs
/// the concrete types to lay out the call, so there is no generic shorthand to offer.
enum ObjC {
    nonisolated(unsafe) private static let msgSendPointer: UnsafeMutableRawPointer =
        dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend")!

    /// `objc_msgSend` as a function of the given C signature.
    static func msgSend<F>(_ type: F.Type) -> F {
        unsafeBitCast(msgSendPointer, to: type)
    }

    /// An object-returning selector with no arguments, or nil when the target does not
    /// answer to it.
    static func object(_ target: AnyObject, _ selector: String) -> AnyObject? {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        return msgSend(Getter.self)(target, sel)
    }

    static func responds(_ target: AnyObject, _ selector: String) -> Bool {
        target.responds(to: NSSelectorFromString(selector))
    }
}
