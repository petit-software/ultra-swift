import AppKit
import IOSurface
import QuartzCore

/// The device's screen in a view: the framebuffer as a layer's contents, aspect-fit, with
/// the pointer as a finger and the keyboard as the device's keyboard.
///
/// Content, not chrome: the screen is opaque and fills what it can, the way terminal text
/// does. The pane around it is the tile's.
public final class SimulatorDisplayView: NSView {

    /// What to draw. An `IOSurface` from a live display, or a `CGImage` for a preview or a
    /// device that is not booted.
    public var contents: AnyObject? {
        didSet { screen.contents = contents; needsLayout = true }
    }

    /// Pixels of the framebuffer, for placing the screen and mapping a click to a ratio.
    public var pixelSize: CGSize = .zero {
        didSet { if pixelSize != oldValue { needsLayout = true } }
    }

    /// Degrees clockwise: the device's orientation. The framebuffer is always portrait; the
    /// view turns it.
    public var angle: Double = 0 {
        didSet { if angle != oldValue { needsLayout = true } }
    }

    /// Where touches and keys go. Nil shows the screen without taking input.
    public var input: SimulatorInput?

    /// Called on a click, so the pane can take the keyboard.
    public var onClick: (() -> Void)?

    private let screen = CALayer()
    private var dragging = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        screen.contentsGravity = .resize
        screen.magnificationFilter = .linear
        screen.minificationFilter = .trilinear
        screen.isOpaque = true
        screen.backgroundColor = NSColor.black.cgColor
        // The framebuffer's rows run top to bottom, as an image's do; a layer draws its
        // contents that way in a view that is not flipped, so the geometry is left alone
        // and the click maths flips y instead.
        layer?.addSublayer(screen)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isOpaque: Bool { false }

    /// The frame changed: re-set the contents so Core Animation picks up the new pixels.
    /// A layer does not watch an IOSurface; it draws what it had when the contents were set.
    public func frameDidChange() {
        screen.contents = nil
        screen.contents = contents
    }

    // MARK: - Layout

    /// The screen's rectangle in the view, aspect-fit and centred, before rotation.
    var fitted: CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let rotated = isLandscape ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
        let scale = min(bounds.width / rotated.width, bounds.height / rotated.height)
        let size = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    private var isLandscape: Bool {
        let normalised = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        return abs(normalised - 90) < 1 || abs(normalised - 270) < 1
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = fitted
        // The layer keeps the framebuffer's own proportions and is rotated into the box,
        // so a landscape device is a portrait layer turned on its side.
        let unrotated = isLandscape ? CGSize(width: box.height, height: box.width) : box.size
        screen.bounds = CGRect(origin: .zero, size: unrotated)
        screen.position = CGPoint(x: box.midX, y: box.midY)
        screen.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        screen.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: - Touches

    /// A point in the view as a ratio across the device's screen, top-left (0, 0) to
    /// bottom-right (1, 1) in the device's OWN orientation, or nil outside the screen.
    func ratio(for point: CGPoint) -> CGPoint? {
        let box = fitted
        guard box.contains(point) else { return nil }
        // Into the layer's own coordinates, which undoes the rotation.
        let local = screen.convert(point, from: layer)
        let size = screen.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let x = local.x / size.width
        // The view is not flipped: y runs up. The device's y runs down.
        let y = 1 - local.y / size.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public override func mouseDown(with event: NSEvent) {
        onClick?()
        guard let ratio = ratio(for: convert(event.locationInWindow, from: nil)) else { return }
        dragging = true
        input?.touch(.down, at: ratio)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging, let ratio = ratio(for: convert(event.locationInWindow, from: nil)) else { return }
        input?.touch(.moved, at: ratio)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        // A finger lifted outside the screen still lifts: clamp rather than lose the up.
        let ratio = ratio(for: point) ?? edgeRatio(for: point)
        input?.touch(.up, at: ratio)
    }

    private func edgeRatio(for point: CGPoint) -> CGPoint {
        let box = fitted
        guard !box.isEmpty else { return .zero }
        let clamped = CGPoint(x: min(max(point.x, box.minX), box.maxX - 0.01),
                              y: min(max(point.y, box.minY), box.maxY - 0.01))
        return ratio(for: clamped) ?? .zero
    }

    // MARK: - Keys

    public override var acceptsFirstResponder: Bool { input != nil }

    public override func keyDown(with event: NSEvent) {
        guard let input else { super.keyDown(with: event); return }
        input.key(event.keyCode, down: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard let input else { super.keyUp(with: event); return }
        input.key(event.keyCode, down: false)
    }

    public override func resetCursorRects() {
        addCursorRect(fitted, cursor: .pointingHand)
    }
}
