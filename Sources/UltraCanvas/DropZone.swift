import AppKit
import CoreGraphics
import UltraDesign
import UltraLayout

/// The pasteboard type a pane drag carries. Narrow on purpose: dropping arbitrary text on
/// the canvas must not rearrange the layout.
public let panePasteboardType = NSPasteboard.PasteboardType("com.ultra.pane")

/// Where a drop lands within a target pane.
///
/// Five zones: four edges and a centre. Edges move the pane into a new split; the centre
/// swaps the two panes. See docs/01-SPLIT-ENGINE.md § 7.
public enum DropZone: Equatable, Sendable {
    case edge(UltraLayout.Edge)
    case centre

    /// Which zone a point falls in.
    ///
    /// `inset` is the fraction of each side given to its edge zone, so the default leaves
    /// the middle 40% × 40% as the centre. Outside that, the winner is the nearest side in
    /// NORMALISED units — which is exactly the rect's diagonals, the rule people already
    /// know from window snapping. Using physical distance instead would make a wide pane's
    /// top band swallow most of its left band.
    public static func at(_ point: CGPoint, in frame: CGRect, inset: CGFloat = 0.3) -> DropZone {
        guard frame.width > 0, frame.height > 0 else { return .centre }
        let u = (point.x - frame.minX) / frame.width
        let v = (point.y - frame.minY) / frame.height
        if u >= inset, u <= 1 - inset, v >= inset, v <= 1 - inset { return .centre }

        let distances: [(UltraLayout.Edge, CGFloat)] =
            [(.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)]
        return .edge(distances.min { $0.1 < $1.1 }!.0)
    }

    /// The region to highlight — a preview of where the pane will end up, not a label.
    public func indicator(in frame: CGRect) -> CGRect {
        switch self {
        case .centre:
            return frame
        case .edge(let edge):
            switch edge {
            case .left: return CGRect(x: frame.minX, y: frame.minY,
                                      width: frame.width / 2, height: frame.height)
            case .right: return CGRect(x: frame.midX, y: frame.minY,
                                       width: frame.width / 2, height: frame.height)
            case .top: return CGRect(x: frame.minX, y: frame.minY,
                                     width: frame.width, height: frame.height / 2)
            case .bottom: return CGRect(x: frame.minX, y: frame.midY,
                                        width: frame.width, height: frame.height / 2)
            }
        }
    }

    public var accessibilityDescription: String {
        switch self {
        case .centre: "Swap panes"
        case .edge(let edge): "Move to \(edge.actionName.lowercased()) of pane"
        }
    }
}

/// A tinted glass rectangle previewing where a dragged pane will land.
///
/// Glass belongs here: it is chrome floating above content, exactly the navigation layer
/// the material is for.
@MainActor
final class DropIndicatorView: NSView {
    private let glass = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.tintColor = Token.Colour.accent.nsColor
        glass.cornerRadius = Token.Space.paneRadius
        glass.contentView = NSView()
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        isHidden = true

        // Under Reduce Transparency the material is replaced by a solid, high-contrast
        // fill rather than being quietly dropped.
        if Token.Environment_.reduceTransparency {
            glass.isHidden = true
            layer?.backgroundColor = Token.Colour.accent.nsColor.withAlphaComponent(0.35).cgColor
        }
        layer?.borderWidth = 2
        layer?.borderColor = Token.Colour.accent.nsColor.cgColor
        layer?.cornerRadius = Token.Space.paneRadius
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// Purely decorative and must never take the mouse mid-drag.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = rect
        glass.frame = bounds
        isHidden = false
        CATransaction.commit()
    }

    func hide() { isHidden = true }
}
