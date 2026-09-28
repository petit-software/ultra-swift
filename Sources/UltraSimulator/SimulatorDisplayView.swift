import AppKit
import IOSurface
import QuartzCore

/// The device in a view: its enclosure, when Xcode has one for it, and the framebuffer as
/// a layer's contents inside it — aspect-fit, with the pointer as a finger and the keyboard
/// as the device's keyboard.
///
/// The enclosure and screen are one layer turned together, so a landscape device is the
/// whole phone on its side, not a screen in an upright bezel.
public final class SimulatorDisplayView: NSView {

    /// What to draw. An `IOSurface` from a live display, or a `CGImage` for a preview or a
    /// device that is not booted.
    public var contents: AnyObject? {
        didSet { screen.contents = contents; needsLayout = true }
    }

    /// Pixels of the framebuffer, for placing the screen when there is no enclosure.
    public var pixelSize: CGSize = .zero {
        didSet { if pixelSize != oldValue { needsLayout = true } }
    }

    /// Degrees clockwise: the device's orientation. The framebuffer is always portrait; the
    /// view turns it.
    public var angle: Double = 0 {
        didSet { if angle != oldValue { needsLayout = true } }
    }

    /// The enclosure drawn round the screen. Nil shows the bare screen.
    public var chrome: DeviceChrome? {
        didSet {
            enclosure.contents = chrome?.image
            if let mask = chrome?.screenMask {
                screenMask.contents = mask
                screen.mask = screenMask
            } else {
                screen.mask = nil
            }
            needsLayout = true
        }
    }

    /// Where touches and keys go. Nil shows the screen without taking input.
    public var input: SimulatorInput?

    /// Called on a click, so the pane can take the keyboard.
    public var onClick: (() -> Void)?

    private let device = CALayer()
    private let enclosure = CALayer()
    private let screen = CALayer()
    private let screenMask = CALayer()
    private var dragging = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        screen.contentsGravity = .resize
        screen.magnificationFilter = .linear
        screen.minificationFilter = .trilinear
        screen.backgroundColor = NSColor.black.cgColor
        enclosure.contentsGravity = .resize
        enclosure.minificationFilter = .trilinear
        screenMask.contentsGravity = .resize
        // The framebuffer's rows run top to bottom, as an image's do; a layer draws its
        // contents that way in a view that is not flipped, so the geometry is left alone
        // and the click maths flips y instead.
        device.addSublayer(enclosure)
        device.addSublayer(screen)
        layer?.addSublayer(device)
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

    /// The device, upright, in its own units: the enclosure with the screen in it, or the
    /// bare screen in pixels. Zero when there is nothing to show.
    private var unrotated: (size: CGSize, screen: CGRect) {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return (.zero, .zero) }
        if let chrome { return (chrome.size, chrome.screen) }
        return (pixelSize, CGRect(origin: .zero, size: pixelSize))
    }

    /// The device's rectangle in the view, aspect-fit and centred, after rotation.
    var fitted: CGRect {
        let size = unrotated.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let rotated = isLandscape ? CGSize(width: size.height, height: size.width) : size
        // A little air round an enclosure, so the buttons do not touch the pane's edge.
        let room = chrome == nil ? bounds : bounds.insetBy(dx: 8, dy: 8)
        let scale = min(room.width / rotated.width, room.height / rotated.height)
        let fit = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        return CGRect(x: (bounds.width - fit.width) / 2, y: (bounds.height - fit.height) / 2,
                      width: fit.width, height: fit.height)
    }

    /// The screen's rectangle in the view: what takes clicks and shows the hand.
    var screenRect: CGRect {
        guard !fitted.isEmpty, let host = layer else { return .zero }
        return screen.convert(screen.bounds, to: host)
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
        let (size, screenInDevice) = unrotated
        // The layer keeps the device's own proportions and is rotated into the box, so a
        // landscape device is a portrait layer turned on its side.
        let upright = isLandscape ? CGSize(width: box.height, height: box.width) : box.size
        let scale = size.width > 0 ? upright.width / size.width : 0
        device.bounds = CGRect(origin: .zero, size: upright)
        device.position = CGPoint(x: box.midX, y: box.midY)
        device.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        enclosure.frame = device.bounds
        enclosure.isHidden = chrome == nil || box.isEmpty
        // The device's units run down from the top; the layer's run up.
        screen.frame = CGRect(x: screenInDevice.minX * scale,
                              y: upright.height - screenInDevice.maxY * scale,
                              width: screenInDevice.width * scale, height: screenInDevice.height * scale)
        screenMask.frame = screen.bounds
        let backing = window?.backingScaleFactor ?? 2
        screen.contentsScale = backing
        enclosure.contentsScale = backing
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: - Touches

    /// A point in the view as a ratio across the device's screen, top-left (0, 0) to
    /// bottom-right (1, 1) in the device's OWN orientation, or nil outside the screen.
    func ratio(for point: CGPoint) -> CGPoint? {
        guard !fitted.isEmpty else { return nil }
        // Into the layer's own coordinates, which undoes the rotation.
        let local = screen.convert(point, from: layer)
        let size = screen.bounds.size
        guard size.width > 0, size.height > 0, screen.bounds.contains(local) else { return nil }
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
        guard !fitted.isEmpty else { return .zero }
        let local = screen.convert(point, from: layer)
        let size = screen.bounds.size
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(max(local.x / size.width, 0), 1), y: min(max(1 - local.y / size.height, 0), 1))
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
        addCursorRect(screenRect, cursor: .pointingHand)
    }
}
