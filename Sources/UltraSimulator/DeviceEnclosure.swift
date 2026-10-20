import CoreGraphics
import Foundation

/// The device's body, drawn here rather than taken from Xcode.
///
/// Xcode's chrome bundles are the right GEOMETRY — where the screen sits in the body,
/// how round its corners are — and the wrong picture: a flat slab with a hairline, the
/// same one for a whole generation. So the geometry is kept (`DeviceChrome.geometry`)
/// and the picture is this: a soft body in the finish's colour, with the screen's black
/// glass set into it. No cameras, no buttons, no ports — the shape is the outline, the
/// radius and the colour, and the rest would be a drawing of a phone round a phone.
public enum DeviceEnclosure {

    /// Everything the drawing needs, in device points with y running down.
    public struct Spec: Equatable, Sendable {
        public var family: DeviceFamily
        public var finish: DeviceFinish
        public var size: CGSize
        public var body: CGRect
        public var screen: CGRect
        public var cornerRadius: CGFloat

        public init(family: DeviceFamily, finish: DeviceFinish, size: CGSize, body: CGRect,
                    screen: CGRect, cornerRadius: CGFloat) {
            self.family = family
            self.finish = finish
            self.size = size
            self.body = body
            self.screen = screen
            self.cornerRadius = cornerRadius
        }

        /// How much of the body shows round the glass.
        public var railWidth: CGFloat { max(2, body.width * family.railRatio) }
    }

    /// The enclosure. The screen is not here; the view lays it on top at `screen`.
    public static func front(_ spec: Spec, scale: CGFloat) -> CGImage? {
        draw(size: spec.size, scale: scale) { context in
            let colour = spec.finish.rail
            let body = CGPath(roundedRect: spec.body, cornerWidth: spec.cornerRadius,
                              cornerHeight: spec.cornerRadius, transform: nil)
            // The body: the finish, a little lighter at the top than the bottom, the way
            // anything matte sits under a room's light. Soft on purpose — no metal
            // gradient, no catch light — so the device never competes with its screen.
            context.saveGState()
            context.addPath(body)
            context.clip()
            fill(context, spec.body, from: colour.lit(1.05), to: colour.lit(0.93))
            context.restoreGState()
            // A soft edge, so a light finish still ends somewhere on a light pane, and a
            // hint of a highlight inside the top of it.
            context.addPath(body)
            context.setStrokeColor(CGColor(gray: 0, alpha: colour.luminance > 0.6 ? 0.18 : 0.3))
            context.setLineWidth(0.8)
            context.strokePath()
            context.saveGState()
            context.addPath(body)
            context.clip()
            context.addPath(CGPath(roundedRect: spec.body.insetBy(dx: 0.8, dy: 0.8),
                                   cornerWidth: max(0, spec.cornerRadius - 0.8),
                                   cornerHeight: max(0, spec.cornerRadius - 0.8), transform: nil))
            context.setStrokeColor(CGColor(gray: 1, alpha: colour.luminance > 0.6 ? 0.5 : 0.22))
            context.setLineWidth(0.8)
            context.strokePath()
            context.restoreGState()

            // The glass round the screen: black, with its own edge where it meets the body.
            let inset = spec.railWidth
            let glass = spec.body.insetBy(dx: inset, dy: inset)
            let radius = max(0, spec.cornerRadius - inset)
            let glassPath = CGPath(roundedRect: glass, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.saveGState()
            context.addPath(glassPath)
            context.clip()
            fill(context, glass, from: DeviceColor(hex: 0x111113), to: DeviceColor(hex: 0x070708))
            context.restoreGState()
            context.addPath(glassPath)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
            context.setLineWidth(1)
            context.strokePath()
        }
    }

    /// A linear gradient over a rect, top to bottom.
    private static func fill(_ context: CGContext, _ rect: CGRect, from: DeviceColor, to: DeviceColor) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: [from.cgColor, to.cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// A bitmap of `size` points at `scale`, drawn with y running down.
    private static func draw(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        body(context)
        return context.makeImage()
    }
}
