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
            applyMask()
            needsLayout = true
        }
    }

    /// The screen's own shape — its rounded corners — as alpha at the framebuffer's aspect,
    /// for a screen shown without an enclosure. The enclosure's mask wins when there is one.
    public var cornerMask: CGImage? {
        didSet { if cornerMask !== oldValue { applyMask() } }
    }

    private func applyMask() {
        if let mask = chrome?.screenMask ?? cornerMask {
            screenMask.contents = mask
            screen.mask = screenMask
        } else {
            screen.mask = nil
        }
    }

    /// Where touches and keys go. Nil shows the screen without taking input.
    public var input: SimulatorInput? {
        willSet { if newValue !== input { input?.releaseAll() } }
    }

    /// Called on a click, so the pane can take the keyboard.
    public var onClick: (() -> Void)?

    private let device = CALayer()
    private let enclosure = CALayer()
    private let screen = CALayer()
    private let screenMask = CALayer()
    private var dragging = false
    private var dragEdge: SimulatorInput.Edge = .none

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
        let scale = min(room.width / rotated.width, room.height / rotated.height) * zoom
        let fit = CGSize(width: rotated.width * scale, height: rotated.height * scale)
        let offset = clampedPan(for: fit)
        return CGRect(x: (bounds.width - fit.width) / 2 + offset.x, y: (bounds.height - fit.height) / 2 + offset.y,
                      width: fit.width, height: fit.height)
    }

    // MARK: - Zoom

    /// How large the device is drawn, as a multiple of the size that fits the pane: 1 fits,
    /// 2 is twice that, with the device panned by scrolling. Clamped to `zoomRange`.
    public var zoom: CGFloat = 1 {
        didSet {
            let clamped = Self.clampZoom(zoom)
            if clamped != zoom { zoom = clamped; return }
            guard zoom != oldValue else { return }
            // Keep the same part of the device in the middle of the pane.
            if oldValue > 0 { pan = CGPoint(x: pan.x * zoom / oldValue, y: pan.y * zoom / oldValue) }
            needsLayout = true
        }
    }

    /// A pinch changed the zoom: the owner keeps it, so the menu and the footer follow.
    public var onZoom: ((CGFloat) -> Void)?

    public static let zoomRange: ClosedRange<CGFloat> = 0.25...4

    /// The stops Zoom In and Zoom Out step through, as multiples of the fitted size.
    public static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    public static func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The next stop up, or down, from `value` — from between two stops, the nearer one in
    /// that direction.
    public static func zoomStep(from value: CGFloat, in: Bool) -> CGFloat {
        let tolerance: CGFloat = 0.01
        if `in` { return zoomSteps.first { $0 > value + tolerance } ?? zoomRange.upperBound }
        return zoomSteps.last { $0 < value - tolerance } ?? zoomRange.lowerBound
    }

    /// Where the device has been scrolled to, from the centre of the pane, in view points.
    private var pan: CGPoint = .zero

    /// The pan, limited so the device cannot be scrolled out of the pane: along an axis
    /// where it is smaller than the pane it stays centred; where it is larger, its edge
    /// stops at the pane's.
    private func clampedPan(for size: CGSize) -> CGPoint {
        let spareX = max(0, (size.width - bounds.width) / 2)
        let spareY = max(0, (size.height - bounds.height) / 2)
        return CGPoint(x: min(max(pan.x, -spareX), spareX), y: min(max(pan.y, -spareY), spareY))
    }

    /// Two fingers pan a device larger than the pane. A device that fits has nothing to
    /// pan, and the scroll goes on up the chain; iOS itself takes no scroll wheel.
    public override func scrollWheel(with event: NSEvent) {
        let box = fitted
        guard !box.isEmpty, box.width > bounds.width || box.height > bounds.height else {
            super.scrollWheel(with: event); return
        }
        // A mouse wheel reports lines, a trackpad points.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let spare = clampedPan(for: box.size)
        pan = CGPoint(x: spare.x + event.scrollingDeltaX * step,
                      y: spare.y - event.scrollingDeltaY * step)   // the view's y runs up
        needsLayout = true
    }

    /// A pinch zooms, about the middle of the pane.
    public override func magnify(with event: NSEvent) {
        guard input != nil || contents != nil else { super.magnify(with: event); return }
        zoom = Self.clampZoom(zoom * (1 + event.magnification))
        onZoom?(zoom)
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
        let point = convert(event.locationInWindow, from: nil)
        let edge = startEdge(for: point)
        // A swipe from the bottom may start on the letterbox just below the screen, as a
        // thumb starts off the glass; it lands on the edge.
        guard let ratio = ratio(for: point) ?? (edge == .bottom ? edgeRatio(for: point) : nil) else { return }
        dragging = true
        dragEdge = edge
        input?.touch(.down, at: ratio, from: edge)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        // Past the screen's edge the finger stays on the edge rather than vanishing: a
        // swipe that overshoots is still the same swipe.
        let point = convert(event.locationInWindow, from: nil)
        input?.touch(.moved, at: ratio(for: point) ?? edgeRatio(for: point), from: dragEdge)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        // A finger lifted outside the screen still lifts: clamp rather than lose the up.
        input?.touch(.up, at: ratio(for: point) ?? edgeRatio(for: point), from: dragEdge)
        dragEdge = .none
    }

    /// How close to the screen's bottom edge, in the pane's points, a touch has to start
    /// to be a swipe from it — inside the screen, or on the band just below it.
    static let edgeBand: CGFloat = 12

    /// The edge a touch starting here starts from: the bottom as the person SEES it, so a
    /// landscape device's home indicator is still at the bottom of the pane.
    func startEdge(for point: CGPoint) -> SimulatorInput.Edge {
        let rect = screenRect
        guard !rect.isEmpty, point.x >= rect.minX, point.x <= rect.maxX else { return .none }
        // The view is not flipped: the bottom is the smallest y.
        let fromBottom = point.y - rect.minY
        return fromBottom >= -Self.edgeBand && fromBottom <= Self.edgeBand ? .bottom : .none
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

    /// A click on a window in the background is still a tap, as it is in Simulator: the
    /// device is the thing being pointed at, not the window around it.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input != nil }

    public override func resignFirstResponder() -> Bool {
        input?.releaseAll()
        return super.resignFirstResponder()
    }

    public override func keyDown(with event: NSEvent) {
        guard let input else { super.keyDown(with: event); return }
        input.key(event)
    }

    public override func keyUp(with event: NSEvent) {
        guard let input else { super.keyUp(with: event); return }
        input.key(event)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard let input, let flag = SimulatorInput.modifierFlag(for: event.keyCode) else {
            super.flagsChanged(with: event); return
        }
        input.modifier(event.keyCode, down: event.modifierFlags.contains(flag))
    }

    public override func resetCursorRects() {
        addCursorRect(screenRect, cursor: .pointingHand)
    }
}
