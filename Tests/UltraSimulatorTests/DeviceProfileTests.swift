import AppKit
import Foundation
import Testing
@testable import UltraSimulator

@Suite("Device profile")
struct DeviceProfileTests {

    /// iPhone Duo's `capabilities.plist`, trimmed to what the parser reads: a cover screen,
    /// an inner screen in an enclosure of its own, and the TV-out every device carries.
    private let duo: [String: Any] = [
        "capabilities": [
            "ArtworkTraits": ["ArtworkDeviceScaleFactor": 3],
            "displays": [
                ["displayType": "integrated", "screenID": 1, "scale": 3, "width": 1398, "height": 2034,
                 "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone15",
                 "framebufferMaskIdentifier": "1C896A2B-F0D7-405C-8D0F-66E4B80AD044"],
                ["displayType": "integrated", "screenID": 3, "scale": 3, "width": 2007, "height": 2853,
                 "chromeIdentifier": "com.apple.dt.devicekit.chrome.phone14",
                 "framebufferMaskIdentifier": "BF0DC480-5EE2-4EC1-B02B-C75E94759832"],
                ["displayType": "tvOut", "screenID": 2, "scale": 1, "width": 720, "height": 480],
            ],
        ] as [String: Any],
    ]

    @Test("a phone that folds has two screens of its own, the cover first, and nothing attached")
    func foldable() throws {
        let profile = try #require(DeviceProfile.parse(profile: [:], capabilities: duo))
        #expect(profile.isFoldable)
        #expect(profile.screens.map(\.id) == [1, 3])
        #expect(profile.primary.chromeIdentifier == "com.apple.dt.devicekit.chrome.phone15")
        #expect(profile.screen(3).chromeIdentifier == "com.apple.dt.devicekit.chrome.phone14")
        #expect(profile.screen(3).pointSize == CGSize(width: 669, height: 951))
        // An id the device does not have means its main screen.
        #expect(profile.screen(9).id == 1)
        #expect(profile.screen(nil).id == 1)
    }

    @Test("an older device type with no display list is one screen, from its profile")
    func older() throws {
        let profile = try #require(DeviceProfile.parse(
            profile: ["chromeIdentifier": "com.apple.dt.devicekit.chrome.phone11", "framebufferMask": "MASK"],
            capabilities: ["capabilities": ["ArtworkTraits": ["ArtworkDeviceScaleFactor": 3]]]))
        #expect(!profile.isFoldable)
        #expect(profile.primary.id == 1)
        #expect(profile.primary.maskIdentifier == "MASK")
        #expect(profile.primary.scale == 3)
        #expect(DeviceProfile.parse(profile: [:], capabilities: [:]) == nil)
    }
}

@Suite("Device displays and orientation")
struct DeviceDisplayTests {

    /// `devicectl device info displays --json-output`, trimmed: the Duo opened.
    private let opened = """
    { "info": { "outcome": "success" },
      "result": {
        "displays": [
          { "active": false, "displayId": 1, "currentOrientation": "rot0", "type": { "integrated": {} } },
          { "active": true, "displayId": 3, "currentOrientation": "rot90", "type": { "integrated": {} } },
          { "active": false, "displayId": 2, "type": { "tvOut": {} } }
        ],
        "orientation": { "currentDeviceOrientation": "landscapeRight" } } }
    """

    @Test("the displays decode as the built-in screens and which is lit")
    func displays() throws {
        let states = try #require(SimulatorControl.parseDisplays(Data(opened.utf8)))
        #expect(states == [.init(id: 1, isActive: false), .init(id: 3, isActive: true)])
        #expect(SimulatorControl.parseDisplays(Data("not json".utf8)) == nil)
    }

    @Test("an interface orientation turns the picture the way that stands it up")
    func angles() {
        #expect(SimulatorDisplay.angle(forInterfaceOrientation: 1) == 0)
        #expect(SimulatorDisplay.angle(forInterfaceOrientation: 2) == 180)
        // Landscape left: the device turned clockwise, its interface drawn running up.
        #expect(SimulatorDisplay.angle(forInterfaceOrientation: 3) == 90)
        #expect(SimulatorDisplay.angle(forInterfaceOrientation: 4) == 270)
        #expect(SimulatorDisplay.angle(forInterfaceOrientation: 0) == 0)
    }
}

@Suite("Folding")
struct SimulatorFoldTests {

    @Test("the helper is built for the simulator, with its entitlement in the section a simulator reads")
    func build() throws {
        let arguments = SimulatorFold.buildArguments(source: URL(fileURLWithPath: "/tmp/f.m"),
                                                     entitlements: URL(fileURLWithPath: "/tmp/f.plist"),
                                                     output: URL(fileURLWithPath: "/tmp/f"))
        #expect(arguments.prefix(3) == ["-sdk", "iphonesimulator", "clang"])
        #expect(arguments.contains { $0.hasSuffix("-apple-ios17.0-simulator") })
        let joined = arguments.joined(separator: " ")
        #expect(joined.contains("-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker /tmp/f.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(SimulatorFold.entitlements.utf8), format: nil) as? [String: Bool])
        #expect(plist == ["com.apple.springboard.sbdisplay.service": true])
    }
}

/// Xcode's own artwork, drawn. Each test returns early on a Mac without the device type.
@Suite("Device chrome from Xcode")
@MainActor
struct DeviceChromeArtworkTests {

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/\(name).simdevicetype")
    }

    @Test("iPhone Duo's cover and inner screens each get their own body, at their own size")
    func duo() throws {
        guard exists("iPhone Duo") else { return }
        let type = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"
        let cover = try #require(DeviceChrome.load(deviceType: type))
        let inner = try #require(DeviceChrome.load(deviceType: type, screenID: 3))
        #expect(abs(cover.screen.width - 466) < 0.5 && abs(cover.screen.height - 678) < 0.5)
        #expect(abs(inner.screen.width - 669) < 0.5 && abs(inner.screen.height - 951) < 0.5)
        #expect(inner.size.width > cover.size.width)
        // Drawn from the composite body: the middle of the cover's left edge is solid, not
        // the red "unused" placeholder its nine pieces are.
        let pixel = try #require(Self.pixel(cover, at: CGPoint(x: cover.screen.minX / 2, y: cover.size.height / 2)))
        #expect(pixel.alpha > 0.9)
        #expect(!(pixel.red > 0.8 && pixel.green < 0.3))
    }

    @Test("a tablet's sides are solid, not the faded bands tiled one-point slices drew")
    func tabletSides() throws {
        guard exists("iPad mini (A17 Pro)") else { return }
        let chrome = try #require(DeviceChrome.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-mini-A17-Pro"))
        for x in stride(from: 4, to: chrome.screen.minX - 4, by: 6) {
            let pixel = try #require(Self.pixel(chrome, at: CGPoint(x: x, y: chrome.size.height / 2)))
            #expect(pixel.alpha > 0.95, "x=\(x): alpha \(pixel.alpha)")
        }
    }

    /// One pixel of the drawn enclosure, at a point in its own units, y running down.
    private static func pixel(_ chrome: DeviceChrome, at point: CGPoint)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        let rep = NSBitmapImageRep(cgImage: chrome.image)
        let scale = CGFloat(rep.pixelsWide) / chrome.size.width
        guard let colour = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
            .usingColorSpace(.sRGB) else { return nil }
        return (colour.redComponent, colour.greenComponent, colour.blueComponent, colour.alphaComponent)
    }
}
