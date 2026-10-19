import AppKit
import Foundation

/// The device's enclosure — body, bezel and side buttons — as Xcode's Simulator draws it.
///
/// Read from the same files: each of a device type's screens (`DeviceProfile`) names a
/// chrome bundle in `/Library/Developer/DeviceKit/Chrome`, whose `chrome.json` is the body —
/// one composite PDF in newer bundles, a nine-part frame of PDF pieces in older ones — sized
/// around the screen, and a list of buttons anchored to its edges. The device type also has
/// the screen's own mask, the rounded corners and nothing else.
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

    /// The chrome round one of a device type's screens — its main one unless `screenID`
    /// names another — or nil when Xcode has none for it. Cached: the files are Xcode's and
    /// do not change under a running app.
    public static func load(deviceType: String, screenID: UInt32? = nil) -> DeviceChrome? {
        guard let profile = DeviceProfile.load(deviceType: deviceType) else { return nil }
        let screen = profile.screen(screenID)
        let key = "\(deviceType)#\(screen.id)"
        if let cached = cache[key] { return cached }
        let made = make(deviceType: deviceType, screen: screen)
        cache[key] = made
        return made
    }

    private static let chromeRoot = URL(fileURLWithPath: "/Library/Developer/DeviceKit/Chrome")
    private static let framebufferMaskRoot = URL(fileURLWithPath: "/Library/Developer/DeviceKit/FramebufferMasks")

    private static var maskCache: [String: CGImage?] = [:]

    /// The screen's own shape for a device type — its rounded corners, and nothing else —
    /// as alpha at the screen's aspect, or nil when Xcode has none for it.
    ///
    /// Apart from the enclosure on purpose: the screen of every device has its own radius,
    /// and a pane that shows the bare screen still wants it. The same PDF the enclosure's
    /// mask is drawn from, the one Simulator itself clips the framebuffer with.
    public static func cornerMask(deviceType: String, screenID: UInt32? = nil) -> CGImage? {
        guard let profile = DeviceProfile.load(deviceType: deviceType) else { return nil }
        let screen = profile.screen(screenID)
        let key = "\(deviceType)#\(screen.id)"
        if let cached = maskCache[key] { return cached }
        let made = maskPDF(deviceType: deviceType, screen: screen).flatMap(maskImage)
        maskCache[key] = made
        return made
    }

    /// The mask PDF of a screen: in the device type's own resources, or Xcode's shared folder.
    private static func maskPDF(deviceType: String, screen: DeviceProfile.Screen) -> NSImage? {
        guard let name = screen.maskIdentifier, let resources = DeviceProfile.resources(for: deviceType) else { return nil }
        let candidates = [resources.appendingPathComponent("\(name).pdf"),
                          framebufferMaskRoot.appendingPathComponent("\(name).pdf")]
        guard let mask = candidates.lazy.compactMap({ NSImage(contentsOf: $0) }).first,
              mask.size.width > 0, mask.size.height > 0 else { return nil }
        return mask
    }

    /// A mask PDF drawn small enough to be cheap and large enough that a corner is smooth.
    private static func maskImage(_ mask: NSImage) -> CGImage? {
        draw(size: mask.size, scale: min(2, 1200 / max(mask.size.width, mask.size.height))) { rect in
            mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static func make(deviceType: String, screen: DeviceProfile.Screen) -> DeviceChrome? {
        guard let chromeID = screen.chromeIdentifier,
              let chromeName = chromeID.split(separator: ".").last else { return nil }
        let chromeDir = chromeRoot.appendingPathComponent("\(chromeName).devicechrome/Contents/Resources")
        guard let data = try? Data(contentsOf: chromeDir.appendingPathComponent("chrome.json")),
              let json = try? JSONDecoder().decode(ChromeFile.self, from: data) else { return nil }

        // The screen in points, from the profile's pixels and scale. An older device type
        // gives no pixels, and its mask PDF is drawn at the screen's pixel size; a newer
        // one's mask is not, so the profile comes first.
        let maskPicture = maskPDF(deviceType: deviceType, screen: screen)
        let screenPoints: CGSize
        if screen.pixelSize.width > 0, screen.pixelSize.height > 0 {
            screenPoints = screen.pointSize
        } else if let pixels = maskPicture?.size, screen.scale > 0 {
            screenPoints = CGSize(width: pixels.width / screen.scale, height: pixels.height / screen.scale)
        } else {
            screenPoints = .zero
        }
        guard screenPoints.width > 0, screenPoints.height > 0 else { return nil }

        func image(_ name: String?) -> NSImage? {
            name.flatMap { NSImage(contentsOf: chromeDir.appendingPathComponent("\($0).pdf")) }
        }
        let pieces = json.images
        // Newer enclosures are drawn whole: one composite of the body, at the size of the
        // device it was drawn for, with the nine pieces left as placeholders that say
        // "unused" in red. Older ones have only the pieces.
        let composite = image(pieces.composite)
        let parts = NinePart(topLeft: image(pieces.topLeft), top: image(pieces.top),
                             topRight: image(pieces.topRight), left: image(pieces.left),
                             right: image(pieces.right), bottomLeft: image(pieces.bottomLeft),
                             bottom: image(pieces.bottom), bottomRight: image(pieces.bottomRight))
        guard composite != nil || parts.isComplete else { return nil }
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
        let radius = json.paths?.simpleOutsideBorder?.cornerRadiusX ?? 0

        // Two pixels a point, less for a big tablet: the pane rarely shows it larger.
        let renderScale = min(2, 2400 / max(layout.size.width, layout.size.height))
        guard let drawn = draw(size: layout.size, scale: renderScale, { _ in
            for (index, button) in buttonImages.enumerated() where !button.onTop {
                button.0.draw(in: layout.buttons[index], from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
            if let composite {
                drawStretched(composite, in: layout.body, corner: radius, sizing: sizing)
            } else {
                parts.draw(in: layout.body, center: center)
            }
            for (index, button) in buttonImages.enumerated() where button.onTop {
                button.0.draw(in: layout.buttons[index], from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
        }) else { return nil }

        let mask = maskPicture.flatMap { mask in
            draw(size: screenPoints, scale: min(2, 1200 / max(screenPoints.width, screenPoints.height))) { rect in
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        return DeviceChrome(image: drawn, size: layout.size, screen: layout.screen, screenMask: mask)
    }

    /// A composite body fitted to a body of another size — the same enclosure serves several
    /// devices — with its corners kept at their own size and only the straight runs between
    /// them stretched, so a corner stays round however tall the device.
    private static func drawStretched(_ composite: NSImage, in body: CGRect, corner: CGFloat, sizing: Insets) {
        let size = composite.size
        guard size.width > 0, size.height > 0 else { return }
        let cap = max(corner, sizing.top, sizing.left, sizing.bottom, sizing.right) + 2
        let capX = min(cap, size.width / 2 - 1, body.width / 2 - 1)
        let capY = min(cap, size.height / 2 - 1, body.height / 2 - 1)
        guard capX > 0, capY > 0 else {
            composite.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        // Source and destination split at the same caps: three columns by three rows.
        let sourceXs = [0, capX, size.width - capX, size.width]
        let sourceYs = [0, capY, size.height - capY, size.height]
        let targetXs = [body.minX, body.minX + capX, body.maxX - capX, body.maxX]
        let targetYs = [body.minY, body.minY + capY, body.maxY - capY, body.maxY]
        for column in 0..<3 {
            for row in 0..<3 {
                // The image's own space runs up from the bottom; the drawing runs down.
                let from = NSRect(x: sourceXs[column], y: size.height - sourceYs[row + 1],
                                  width: sourceXs[column + 1] - sourceXs[column],
                                  height: sourceYs[row + 1] - sourceYs[row])
                let to = NSRect(x: targetXs[column], y: targetYs[row],
                                width: targetXs[column + 1] - targetXs[column],
                                height: targetYs[row + 1] - targetYs[row])
                guard from.width > 0, from.height > 0, to.width > 0, to.height > 0 else { continue }
                composite.draw(in: to, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// The nine pieces of an older enclosure.
    ///
    /// Drawn by hand rather than with `NSDrawNinePartImage`, which TILES the edges. An edge
    /// here is a one-point slice of a PDF, and a one-point slice tiled down a side is drawn
    /// a hair off the pixel grid every time: a tablet's sides came out as faded bands.
    /// Stretched once, the slice is a clean edge at any size.
    private struct NinePart {
        var topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight: NSImage?

        var isComplete: Bool {
            [topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight].allSatisfy { $0 != nil }
        }

        func draw(in body: CGRect, center: NSImage?) {
            guard let topLeft, let top, let topRight, let left, let right,
                  let bottomLeft, let bottom, let bottomRight else { return }
            func put(_ image: NSImage, _ rect: CGRect) {
                guard rect.width > 0, rect.height > 0 else { return }
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // The body's middle is the screen's backing: black round the screen's corners.
            if let center {
                put(center, body.insetBy(dx: topLeft.size.width / 2, dy: topLeft.size.height / 2))
            }
            let tl = topLeft.size, tr = topRight.size, bl = bottomLeft.size, br = bottomRight.size
            // Each edge runs a point under the corners either side of it, so where a corner's
            // antialiased boundary meets it there is edge underneath rather than a seam.
            let tuck: CGFloat = 1
            put(top, CGRect(x: body.minX + tl.width - tuck, y: body.minY,
                            width: body.width - tl.width - tr.width + tuck * 2, height: top.size.height))
            put(bottom, CGRect(x: body.minX + bl.width - tuck, y: body.maxY - bottom.size.height,
                               width: body.width - bl.width - br.width + tuck * 2, height: bottom.size.height))
            put(left, CGRect(x: body.minX, y: body.minY + tl.height - tuck,
                             width: left.size.width, height: body.height - tl.height - bl.height + tuck * 2))
            put(right, CGRect(x: body.maxX - right.size.width, y: body.minY + tr.height - tuck,
                              width: right.size.width, height: body.height - tr.height - br.height + tuck * 2))
            put(topLeft, CGRect(origin: CGPoint(x: body.minX, y: body.minY), size: tl))
            put(topRight, CGRect(origin: CGPoint(x: body.maxX - tr.width, y: body.minY), size: tr))
            put(bottomLeft, CGRect(origin: CGPoint(x: body.minX, y: body.maxY - bl.height), size: bl))
            put(bottomRight, CGRect(origin: CGPoint(x: body.maxX - br.width, y: body.maxY - br.height), size: br))
        }
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
            var composite: String?
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
        struct Paths: Decodable {
            struct Border: Decodable { var cornerRadiusX: CGFloat? }
            var simpleOutsideBorder: Border?
        }
        var images: Images
        var paths: Paths?
        var inputs: [Input]?
    }
}
