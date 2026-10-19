import CoreGraphics
import Foundation

/// What a device type says about its screens: one for almost every device, two for a phone
/// that folds.
///
/// Read from the device type's own bundle in `/Library/Developer/CoreSimulator/Profiles`.
/// Its `capabilities.plist` lists every display the hardware has, each with the enclosure it
/// sits in and the mask that rounds its corners; `profile.plist` names one of each for the
/// device as a whole, which is all an older device type says.
///
/// An iPhone Duo has a cover screen (id 1) and, opened, an inner one (id 3) with an
/// enclosure of its own. Which of them is lit is the device's business — see
/// `SimulatorControl.displays` — but which ones there ARE, and what each looks like, is here.
public struct DeviceProfile: Equatable, Sendable {

    public struct Screen: Equatable, Sendable {
        /// The id the display port and `devicectl` both use for it.
        public var id: UInt32
        /// `com.apple.dt.devicekit.chrome.phone15`: which enclosure to draw round it.
        public var chromeIdentifier: String?
        /// The PDF, in the device type's resources, that is the screen's own shape.
        public var maskIdentifier: String?
        /// Pixels per point.
        public var scale: CGFloat
        /// The framebuffer, in pixels, portrait as the hardware is built.
        public var pixelSize: CGSize

        public init(id: UInt32, chromeIdentifier: String?, maskIdentifier: String?,
                    scale: CGFloat, pixelSize: CGSize) {
            self.id = id
            self.chromeIdentifier = chromeIdentifier
            self.maskIdentifier = maskIdentifier
            self.scale = scale
            self.pixelSize = pixelSize
        }

        /// The screen in points, which is what its enclosure is drawn round.
        public var pointSize: CGSize {
            guard scale > 0 else { return pixelSize }
            return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        }
    }

    /// The device's built-in screens, the main one first. Never empty.
    public var screens: [Screen]

    public init(screens: [Screen]) {
        self.screens = screens
    }

    /// The screen a device shows when nothing says otherwise: its main one.
    public var primary: Screen { screens[0] }

    /// A device with a second built-in screen is one that folds: closed it shows the first,
    /// open the second.
    public var isFoldable: Bool { screens.count > 1 }

    public func screen(_ id: UInt32?) -> Screen {
        id.flatMap { id in screens.first { $0.id == id } } ?? primary
    }

    // MARK: - Parsing

    /// The profile from the two plists, or nil when neither names a screen. Pure, so it is
    /// tested against fixtures rather than against whatever Xcode happens to be installed.
    ///
    /// Only `integrated` displays count: the TV-out, CarPlay and resizable displays in the
    /// same list are screens something else attaches, not the device's own.
    public static func parse(profile: [String: Any], capabilities: [String: Any]) -> DeviceProfile? {
        let caps = capabilities["capabilities"] as? [String: Any] ?? capabilities
        let traits = caps["ArtworkTraits"] as? [String: Any]
        let deviceScale = number(traits?["ArtworkDeviceScaleFactor"]) ?? 0
        let displays = caps["displays"] as? [[String: Any]] ?? []
        let integrated = displays.compactMap { display -> Screen? in
            guard display["displayType"] as? String == "integrated",
                  let id = number(display["screenID"]) else { return nil }
            return Screen(id: UInt32(id),
                          chromeIdentifier: display["chromeIdentifier"] as? String,
                          maskIdentifier: display["framebufferMaskIdentifier"] as? String,
                          scale: number(display["scale"]) ?? deviceScale,
                          pixelSize: CGSize(width: number(display["width"]) ?? 0,
                                            height: number(display["height"]) ?? 0))
        }
        if !integrated.isEmpty { return DeviceProfile(screens: integrated) }
        // An older device type: one screen, described by the profile.
        let chrome = profile["chromeIdentifier"] as? String
        let mask = profile["framebufferMask"] as? String
        guard chrome != nil || mask != nil else { return nil }
        return DeviceProfile(screens: [Screen(id: 1, chromeIdentifier: chrome, maskIdentifier: mask,
                                              scale: deviceScale, pixelSize: .zero)])
    }

    private static func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat(truncating: $0) }
    }

    // MARK: - Loading

    @MainActor private static var cache: [String: DeviceProfile?] = [:]

    /// The profile for a device type identifier, or nil when Xcode has no bundle for it.
    /// Cached: the files are Xcode's and do not change under a running app.
    @MainActor
    public static func load(deviceType: String) -> DeviceProfile? {
        guard !deviceType.isEmpty else { return nil }
        if let cached = cache[deviceType] { return cached }
        let made = resources(for: deviceType).flatMap { resources -> DeviceProfile? in
            let profile = NSDictionary(contentsOf: resources.appendingPathComponent("profile.plist")) as? [String: Any]
            let capabilities = NSDictionary(contentsOf: resources.appendingPathComponent("capabilities.plist")) as? [String: Any]
            return parse(profile: profile ?? [:], capabilities: capabilities ?? [:])
        }
        cache[deviceType] = made
        return made
    }

    /// Where device types live: the shared profiles, and inside Xcode for older ones.
    private static var deviceTypeRoots: [URL] {
        var roots = [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")]
        if let developer = SimulatorControl.developerDirectory {
            roots.append(URL(fileURLWithPath: developer).appendingPathComponent(
                "Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes"))
        }
        return roots
    }

    @MainActor private static var bundles: [String: URL?] = [:]

    /// The device type's `Contents/Resources`, found by its bundle identifier.
    @MainActor
    static func resources(for deviceType: String) -> URL? {
        if let known = bundles[deviceType] { return known }
        let files = FileManager.default
        var found: URL?
        search: for root in deviceTypeRoots {
            guard let names = try? files.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasSuffix(".simdevicetype") {
                let url = root.appendingPathComponent(name)
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                if info?["CFBundleIdentifier"] as? String == deviceType {
                    found = url.appendingPathComponent("Contents/Resources")
                    break search
                }
            }
        }
        bundles[deviceType] = found
        return found
    }
}
