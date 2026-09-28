import AppKit
import Foundation

/// The device's enclosure — body, bezel and side buttons — as Xcode's Simulator draws it.
///
/// Read from the same files: a device type's `profile.plist` names a chrome bundle in
/// `/Library/Developer/DeviceKit/Chrome`, whose `chrome.json` is a nine-part frame of PDF
/// pieces sized around the screen, and a list of buttons anchored to its edges. The
/// device type also has the screen's own mask, the rounded corners and nothing else.
///
/// Drawn once, into one image; the view places the live screen on top at `screen`.
@MainActor
public struct DeviceChrome {

    /// The enclosure, buttons included, drawn at `size` points times some scale.
    public let image: CGImage
    /// The whole enclosure in points, buttons included.
    public let size: CGSize
    /// Where the screen goes, in points, from the top-left of `size`.
    public let screen: CGRect
    /// The screen's shape, as alpha, at the framebuffer's aspect. Nil if the device type
    /// has none; the screen is then square-cornered.
    public let screenMask: CGImage?

    // MARK: - Geometry

    /// Where every piece goes, in points with y running down. Pure, so it is tested.
    public struct Geometry: Equatable, Sendable {
        public var size: CGSize
        /// The body: the nine-part frame, the screen outset by the frame's sizing.
        public var body: CGRect
        public var screen: CGRect
        public var buttons: [CGRect]
    }

    public struct Insets: Equatable, Sendable {
        public var top, left, bottom, right: CGFloat
        public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
            self.top = top; self.left = left; self.bottom = bottom; self.right = right
        }
    }

    /// A button on the body's edge. `offset` is chrome.json's: along the edge from its
    /// leading or trailing end, and across it from the body's outline, where a positive x
    /// on the left edge (or y on the top) tucks the button back behind the body.
    public struct ButtonPlacement: Equatable, Sendable {
        public enum Anchor: String, Sendable { case left, right, top, bottom }
        public var size: CGSize
        public var anchor: Anchor
        public var trailing: Bool
        public var offset: CGPoint

        public init(size: CGSize, anchor: Anchor, trailing: Bool, offset: CGPoint) {
            self.size = size; self.anchor = anchor; self.trailing = trailing; self.offset = offset
        }
    }

    public static func geometry(screen: CGSize, sizing: Insets, buttons: [ButtonPlacement]) -> Geometry {
        var body = CGRect(x: 0, y: 0, width: screen.width + sizing.left + sizing.right,
                          height: screen.height + sizing.top + sizing.bottom)
        var rects = buttons.map { button -> CGRect in
            let w = button.size.width, h = button.size.height
            var rect = CGRect(origin: .zero, size: button.size)
            switch button.anchor {
            case .left:
                rect.origin.x = body.minX + button.offset.x - w
                rect.origin.y = button.trailing ? body.maxY + button.offset.y - h : body.minY + button.offset.y
            case .right:
                rect.origin.x = body.maxX + button.offset.x
                rect.origin.y = button.trailing ? body.maxY + button.offset.y - h : body.minY + button.offset.y
            case .top:
                rect.origin.y = body.minY + button.offset.y - h
                rect.origin.x = button.trailing ? body.maxX + button.offset.x - w : body.minX + button.offset.x
            case .bottom:
                rect.origin.y = body.maxY + button.offset.y
                rect.origin.x = button.trailing ? body.maxX + button.offset.x - w : body.minX + button.offset.x
            }
            return rect
        }
        // Everything moved so the union starts at the origin.
        let union = rects.reduce(body) { $0.union($1) }
        let shift = CGPoint(x: -union.minX, y: -union.minY)
        body = body.offsetBy(dx: shift.x, dy: shift.y)
        rects = rects.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
        let screenRect = CGRect(x: body.minX + sizing.left, y: body.minY + sizing.top,
                                width: screen.width, height: screen.height)
        return Geometry(size: union.size, body: body, screen: screenRect, buttons: rects)
    }

    // MARK: - Loading

    private static var cache: [String: DeviceChrome?] = [:]

    /// The chrome for a device type identifier, or nil when Xcode has none for it. Cached:
    /// the files are Xcode's and do not change under a running app.
    public static func load(deviceType: String) -> DeviceChrome? {
        guard !deviceType.isEmpty else { return nil }
        if let cached = cache[deviceType] { return cached }
        let made = make(deviceType: deviceType)
        cache[deviceType] = made
        return made
    }

    private static let chromeRoot = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")

    /// Where device types live: the shared profiles, and inside Xcode for older ones.
    private static var deviceTypeRoots: [URL] {
        var roots = [URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")]
        if let developer = SimulatorControl.developerDirectory {
            roots.append(URL(fileURLWithPath: developer).appendingPathComponent(
                "Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/DeviceTypes"))
        }
        return roots
    }

    private static func bundle(for deviceType: String) -> URL? {
        let files = FileManager.default
        for root in deviceTypeRoots {
            guard let names = try? files.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasSuffix(".simdevicetype") {
                let url = root.appendingPathComponent(name)
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                if info?["CFBundleIdentifier"] as? String == deviceType { return url }
            }
        }
        return nil
    }

    private static func make(deviceType: String) -> DeviceChrome? {
        guard let bundle = bundle(for: deviceType) else { return nil }
        let resources = bundle.appendingPathComponent("Contents/Resources")
        guard let profile = NSDictionary(contentsOf: resources.appendingPathComponent("profile.plist")),
              let chromeID = profile["chromeIdentifier"] as? String,
              let chromeName = chromeID.split(separator: ".").last else { return nil }
        let chromeDir = chromeRoot.appendingPathComponent("\(chromeName).devicechrome/Contents/Resources")
        guard let data = try? Data(contentsOf: chromeDir.appendingPathComponent("chrome.json")),
              let json = try? JSONDecoder().decode(ChromeFile.self, from: data) else { return nil }

        // The screen in points: the framebuffer mask is drawn at the screen's pixel size,
        // and the capabilities name the scale.
        let maskURL = (profile["framebufferMask"] as? String).map { resources.appendingPathComponent("\($0).pdf") }
        let maskImage = maskURL.flatMap { NSImage(contentsOf: $0) }
        let capabilities = NSDictionary(contentsOf: resources.appendingPathComponent("capabilities.plist"))
        let traits = (capabilities?["capabilities"] as? NSDictionary)?["ArtworkTraits"] as? NSDictionary
        let scale = (traits?["ArtworkDeviceScaleFactor"] as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? 0
        guard let pixels = maskImage?.size, scale > 0, pixels.width > 0 else { return nil }
        let screenPoints = CGSize(width: pixels.width / scale, height: pixels.height / scale)

        func image(_ name: String?) -> NSImage? {
            name.flatMap { NSImage(contentsOf: chromeDir.appendingPathComponent("\($0).pdf")) }
        }
        let pieces = json.images
        guard let topLeft = image(pieces.topLeft), let top = image(pieces.top), let topRight = image(pieces.topRight),
              let left = image(pieces.left), let right = image(pieces.right),
              let bottomLeft = image(pieces.bottomLeft), let bottom = image(pieces.bottom),
              let bottomRight = image(pieces.bottomRight) else { return nil }
        let center = image(pieces.screen)

        var buttonImages: [(NSImage, onTop: Bool)] = []
        var placements: [ButtonPlacement] = []
        for input in json.inputs ?? [] {
            guard let picture = image(input.image), let anchor = ButtonPlacement.Anchor(rawValue: input.anchor) else { continue }
            buttonImages.append((picture, input.onTop ?? false))
            placements.append(ButtonPlacement(size: picture.size, anchor: anchor,
                                              trailing: input.align == "trailing",
                                              offset: CGPoint(x: input.offsets.normal.x, y: input.offsets.normal.y)))
        }
        let sizing = Insets(top: pieces.sizing.topHeight, left: pieces.sizing.leftWidth,
                            bottom: pieces.sizing.bottomHeight, right: pieces.sizing.rightWidth)
        let layout = geometry(screen: screenPoints, sizing: sizing, buttons: placements)

        // Two pixels a point, less for a big tablet: the pane rarely shows it larger.
        let renderScale = min(2, 2400 / max(layout.size.width, layout.size.height))
        guard let drawn = draw(size: layout.size, scale: renderScale, { _ in
            for (index, button) in buttonImages.enumerated() where !button.onTop {
                button.0.draw(in: layout.buttons[index], from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
            // The body's middle is the screen's backing: black round the screen's corners.
            if let center {
                center.draw(in: layout.body.insetBy(dx: topLeft.size.width / 2, dy: topLeft.size.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSDrawNinePartImage(layout.body, topLeft, top, topRight, left, nil, right,
                                bottomLeft, bottom, bottomRight, .sourceOver, 1, true)
            for (index, button) in buttonImages.enumerated() where button.onTop {
                button.0.draw(in: layout.buttons[index], from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
        }) else { return nil }

        let mask = maskImage.flatMap { mask in
            draw(size: screenPoints, scale: min(2, 1200 / max(screenPoints.width, screenPoints.height))) { rect in
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        return DeviceChrome(image: drawn, size: layout.size, screen: layout.screen, screenMask: mask)
    }

    /// An image of `size` points drawn by AppKit in a flipped context, y running down.
    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGRect) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body(CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: - chrome.json

    private struct ChromeFile: Decodable {
        struct Images: Decodable {
            var topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left: String
            var screen: String?
            var sizing: Sizing
        }
        struct Sizing: Decodable {
            var leftWidth, rightWidth, topHeight, bottomHeight: CGFloat
        }
        struct Input: Decodable {
            struct Offsets: Decodable { var normal: Point }
            struct Point: Decodable { var x, y: CGFloat }
            var image: String?
            var anchor: String
            var align: String?
            var onTop: Bool?
            var offsets: Offsets
        }
        var images: Images
        var inputs: [Input]?
    }
}
