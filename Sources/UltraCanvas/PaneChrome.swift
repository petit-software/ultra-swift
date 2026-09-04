import AppKit
import SwiftUI
import UltraCore
import UltraDesign
import UltraLayout

/// What a pane's chrome can do. Every one of these is also a menu command with a key
/// equivalent — a pointer affordance without a keyboard equivalent is a bug, see the
/// `keyboard-first` skill.
/// One entry in the "turn this pane into…" menu.
public struct PaneKindChoice: Identifiable, Sendable, Equatable {
    public let kind: PaneRecord.Kind
    public let title: String
    public let symbol: String
    public var id: PaneRecord.Kind { kind }

    public init(kind: PaneRecord.Kind, title: String, symbol: String) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
    }
}

@MainActor
public final class PaneActions {
    public var split: (PaneID, UltraLayout.Edge) -> Void
    public var close: (PaneID) -> Void
    public var focus: (PaneID) -> Void
    /// What a pane can become. Supplied by the app, because the canvas knows nothing about
    /// tile kinds — it lays out rectangles.
    public var kinds: () -> [PaneKindChoice]
    public var changeKind: (PaneID, PaneRecord.Kind) -> Void

    public init(split: @escaping (PaneID, UltraLayout.Edge) -> Void,
                close: @escaping (PaneID) -> Void,
                focus: @escaping (PaneID) -> Void,
                kinds: @escaping () -> [PaneKindChoice] = { [] },
                changeKind: @escaping (PaneID, PaneRecord.Kind) -> Void = { _, _ in }) {
        self.split = split
        self.close = close
        self.focus = focus
        self.kinds = kinds
        self.changeKind = changeKind
    }

    /// A fresh do-nothing set. Deliberately a factory rather than a shared instance: this
    /// is a reference type now, and a singleton would let one store's wiring leak into
    /// another's — including into previews.
    public static var inert: PaneActions {
        PaneActions(split: { _, _ in }, close: { _ in }, focus: { _ in })
    }
}

/// The focused pane's ring, as a view so it can sit above the pane's header.
@MainActor
final class PaneRingView: NSView {
    /// The tint is kept as an `NSColor` and resolved on every application, because
    /// `NSColor.cgColor` is WHERE a dynamic colour resolves — and it resolves against
    /// whatever appearance happens to be current, which outside a draw is the light one.
    /// Resolving here rather than at the call site means the ring cannot be handed a colour
    /// that was already flattened against the wrong theme.
    var tint: NSColor = .clear {
        didSet { applyTint() }
    }

    private func applyTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.borderColor = tint.cgColor
        }
    }

    /// The theme changed under a ring that had already flattened its colour.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        applyMetrics()
    }

    /// Re-read the ring's shape. Both numbers are settings now, so setting them once in
    /// `init` would freeze the ring at whatever the app launched with.
    func applyMetrics() {
        layer?.borderWidth = Token.Space.focusRingWidth
        // Concentric with the pane: the radius follows the inset, or the ring bulges at the
        // corners against the rounding it is meant to trace.
        layer?.cornerRadius = max(0, Token.Space.paneRadius - Token.Space.focusRingInset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decorative. It covers the header, so taking clicks would make the title bar dead.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A plain top-left-origin container.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What a pane is, for chrome purposes. From M2 this is filled from the real tile.
public struct PaneDescriptor: Sendable, Equatable {
    public var icon: String
    public var title: String
    public var subtitle: String?

    public init(icon: String = "apple.terminal", title: String, subtitle: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }
}

// MARK: - Header

/// A pane's header: close in the top-left corner, then the pane's identity, then the split
/// controls on the right.
///
/// Glass, because it is the tile's navigation layer sitting above opaque content — never
/// the other way round. See docs/02-DESIGN-LANGUAGE.md.
public struct PaneHeader: View {
    /// The header's own coordinate space, so the identity control can say where it ends in
    /// terms the container's `layout()` understands.
    nonisolated static let coordinateSpace = "paneHeader"

    let paneID: PaneID
    let descriptor: PaneDescriptor
    let currentKind: PaneRecord.Kind?
    let isFocused: Bool
    let canClose: Bool
    let actions: PaneActions
    /// Where the identity control's trailing edge landed, in header coordinates. The drag
    /// handle is an AppKit view laid out by the container, and it must start after the
    /// name — the name is a control now, and a handle over it would take its clicks.
    var onIdentityTrailing: (CGFloat) -> Void = { _ in }

    @State private var isHovering = false

    /// Split and close are always present, so the affordance is discoverable rather than
    /// hidden behind a hover the user has to find. Hovering just brings them forward.
    private var controlOpacity: Double { isHovering ? 1 : (isFocused ? 0.72 : 0.4) }

    public var body: some View {
        // 2 rather than 6: the controls' plates already supply their own breathing room.
        HStack(spacing: 2) {
            // Close leads, in the corner, the way a window's does. It was in the trailing
            // cluster beside Split, where the destructive control sat one pixel from the
            // constructive ones.
            if canClose {
                PaneHeaderButton(symbol: "xmark", help: "Close Pane (⌘W)", isDestructive: true) {
                    actions.close(paneID)
                }
                .opacity(controlOpacity)
                .fixedSize()
            }

            PaneIdentityButton(paneID: paneID, descriptor: descriptor,
                               currentKind: currentKind, isFocused: isFocused,
                               actions: actions)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.coordinateSpace)).maxX
                } action: { onIdentityTrailing($0) }

            Spacer(minLength: 4)

            // The split controls never move and never collapse as the pane narrows: they
            // are fixed-size, so the identity control is the only thing that gives, and it
            // gives by trimming its name.
            HStack(spacing: 1) {
                PaneHeaderButton(symbol: "square.split.2x1", help: "Split Right (⌘D)") {
                    actions.split(paneID, .right)
                }
                PaneHeaderButton(symbol: "square.split.1x2", help: "Split Down (⇧⌘D)") {
                    actions.split(paneID, .bottom)
                }
            }
            .opacity(controlOpacity)
            .fixedSize()
        }
        // 4, not 10: the leading control wears the standard 28-wide hover plate, which
        // carries ~6.5pt of slack either side of the glyph. Padding the header as if the
        // glyph were bare would indent it past everything below it.
        .padding(.leading, 4)
        .padding(.trailing, 5)
        .frame(height: Token.Space.tileHeaderHeight)
        .frame(maxWidth: .infinity)
        .coordinateSpace(.named(Self.coordinateSpace))
        // No background at all, and nothing behind it either. The header's band is the
        // pane's own glass — the content is laid out below it, so there is nothing to hide
        // and nothing to blur. Anything drawn here would be a second surface inside the
        // pane, which is exactly what the header must not read as.
        .onHover { isHovering = $0 }
        // Click-to-focus sits BEHIND the controls rather than on the whole header. On the
        // header itself it consumed the tap before the icon's menu ever saw it: the pane
        // took focus and the menu silently never opened.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { actions.focus(paneID) }
        }
        // No container of its own. `.accessibilityElement(children: .contain)` was here and
        // did two unhelpful things: it repeated the pane's title one level in, and it added
        // a group between the pane and its buttons. The buttons carry their own labels and
        // are more use reached directly.
    }
}

/// A control in a pane header. The chrome itself lives in `ChromeIconButton`, shared with
/// tile footers so the two ends of a tile cannot drift apart again.
struct PaneHeaderButton: View {
    let symbol: String
    let help: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        ChromeIconButton(symbol: symbol, help: help,
                         isDestructive: isDestructive, action: action)
    }
}

/// The pasteboard type a dragged pane travels as.
///
/// A UUID string rather than an archived pane: the pane itself never moves between processes,
/// and a drop only needs to name which one was picked up. Anything richer would be state that
/// can disagree with the tree by the time it lands.
public enum PaneDragType {
    public static let identifier = "com.ultra.pane"
    public static var pasteboard: NSPasteboard.PasteboardType { .init(identifier) }
}

// MARK: - Kind menu

/// The pane's identity — its name — and the "turn this pane into…" control, as one thing.
///
/// The icon alone was the control before, and the name beside it was inert, which meant
/// the biggest target in the header did nothing while the smallest opened a menu. The
/// identity is what says what the pane is, so all of it is what people press to change
/// what the pane is: one hover plate, one click, one menu.
///
/// No icon any more. The name already says what the pane is — "Todo", "Git", a path for
/// a shell — so a glyph beside it was the same fact twice, in the one strip of a pane
/// that has the least room. The kind's symbol still appears where it earns its place:
/// beside each entry in the menu this control opens.
///
/// Falls back to a plain label when the app supplied no kinds — an empty `NSMenu` declines
/// to open, and a control that does nothing is worse than a label.
struct PaneIdentityButton: View {
    let paneID: PaneID
    let descriptor: PaneDescriptor
    let currentKind: PaneRecord.Kind?
    let isFocused: Bool
    let actions: PaneActions

    var body: some View {
        if actions.kinds().isEmpty {
            label(isHovering: false)
        } else {
            // Every kind is also reachable from the palette; the tooltip teaches that
            // rather than pretending this pointer affordance is the only way in.
            ChromeMenuTrigger(help: "Change Pane Type (\u{2318}K)",
                              entries: entries) { hovering in
                label(isHovering: hovering)
            }
        }
    }

    private func entries() -> [ChromeMenuEntry] {
        actions.kinds().map { choice in
            // The pane's current kind is ticked and cannot be re-chosen: converting a pane
            // into what it already is would tear down a live tile to rebuild the same thing.
            .item(title: choice.title, symbol: choice.symbol,
                  isOn: choice.kind == currentKind,
                  isEnabled: choice.kind != currentKind) {
                actions.changeKind(paneID, choice.kind)
            }
        }
    }

    /// The name, with one plate under it on hover.
    private func label(isHovering: Bool) -> some View {
        name
            // One line, trimmed from the tail. The name never wraps, never drops out
            // and never pushes the split controls: as the pane narrows the subtitle
            // goes first, then the title, one character at a time with an ellipsis.
            .lineLimit(1)
            .truncationMode(.tail)
            // The same 8 either side, so the plate is a capsule around the words rather
            // than a box that used to have a glyph in its left half.
            .padding(.horizontal, 8)
            .frame(height: ChromeIconLabel.height)
            .contentShape(.rect)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Token.Colour.label.opacity(0.10))
                }
            }
    }

    /// Title and subtitle as ONE run of text rather than two views, so tail truncation
    /// eats the subtitle before it touches the title — and a subtitle that has been trimmed
    /// to nothing simply is nothing, rather than a lone "…" beside an intact name.
    private var name: Text {
        let title = Text(descriptor.title)
            .font(Token.Type_.tileTitle)
            .foregroundStyle(isFocused ? Token.Colour.label : Token.Colour.secondaryLabel)
        guard let subtitle = descriptor.subtitle else { return title }
        let detail = Text(subtitle)
            .font(Token.Type_.tileSubtitle)
            .foregroundStyle(Token.Colour.tertiaryLabel)
        return Text("\(title)  \(detail)")
    }
}

// MARK: - Container

/// Wraps every pane's content in the tile chrome: rounded clip, header, focus border.
///
/// The content view inside is created once and never replaced, so from M2 the SwiftTerm
/// view and its PTY live here untouched through every split, resize, and close of a sibling.
@MainActor
public final class PaneContainerView: NSView {
    public let content: NSView
    public let paneID: PaneID
    /// The pane's surface: real Liquid Glass, rounded, with the tile's content inside it.
    /// The container itself stays unclipped so it can cast a shadow.
    private let glass = NSGlassEffectView()

    /// The focused pane's ring.
    ///
    /// A VIEW above everything else, not a layer inside the clip. Inside, the header is a
    /// subview of the same clip and therefore draws over it, so the ring vanished along the
    /// whole title band — a three-sided ring, which reads as a rendering fault rather than
    /// as focus.
    ///
    /// Flush with the pane's edge. It was inset while the ring read at full strength
    /// whatever alpha it carried — see `Token.Space.focusRingInset` for why that is no
    /// longer needed, and what it cost.
    private let ring = PaneRingView()
    private let clip = FlippedView()
    private let header: NSHostingView<PaneHeader>
    private var descriptor: PaneDescriptor
    /// What this pane currently is, so its own kind is not offered as a change.
    private var kind: PaneRecord.Kind?
    private let actions: PaneActions

    public var isFocused: Bool = false {
        didSet { guard isFocused != oldValue else { return }; refresh() }
    }

    /// The pane's surface colour, and the ONE place background opacity is painted.
    ///
    /// It used to be painted by the shell — `ShellPaneContainer` under the grid and
    /// SwiftTerm's own layer over it, which double-composited the grid against its own
    /// padding — and by nothing else at all, so the setting simply did not exist for a
    /// Todo, a file tree, a Git pane or an editor. Here it is one fill under one pane, so
    /// every pane answers to the slider and answers to it identically.
    public var theme: TerminalTheme {
        didSet { guard theme != oldValue else { return }; applyBackdrop() }
    }

    /// Inside the glass, under everything: `clip` is the glass's content view, so its own
    /// background sits above the material and below the pane's content.
    private func applyBackdrop() {
        clip.layer?.backgroundColor = NSColor(theme.background)
            .withAlphaComponent(theme.backgroundOpacity).cgColor
    }

    /// Every look setting a pane draws with, in one re-runnable place.
    ///
    /// The corner radius, the shadow and the glass itself were all set once in `init` back
    /// when they were constants. They are settings now, and a setting that only applies to
    /// panes opened afterwards is the exact bug the theme had.
    ///
    /// The three glass properties are assigned unconditionally but read cheaply; the
    /// shadow's opacity is left to `applyLayerState`, which also knows about focus.
    private func applyAppearance() {
        let radius = Token.Space.paneRadius
        clip.layer?.cornerRadius = radius
        glass.cornerRadius = radius
        glass.style = Appearance.glassStyle.style
        // Resolved inside the view's appearance: the accent can be System Accent, which is
        // dynamic, and `tintColor` is handed a resolved colour rather than a promise.
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            glass.tintColor = switch Appearance.glassTint {
            case .off: nil
            case .accent: Token.Colour.accent.nsColor
                .withAlphaComponent(Appearance.glassTintStrength)
            }
        }
        layer?.shadowRadius = Token.Space.paneShadowRadius
        ring.applyMetrics()
        needsLayout = true
    }


    /// The close control disappears when a pane is the last one — there is nothing to
    /// close back to.
    public var canClose: Bool = true {
        didSet { guard canClose != oldValue else { return }; refresh() }
    }

    public init(paneID: PaneID, descriptor: PaneDescriptor, kind: PaneRecord.Kind?,
                content: NSView, actions: PaneActions, theme: TerminalTheme = .dark) {
        self.theme = theme
        self.kind = kind
        self.paneID = paneID
        self.descriptor = descriptor
        self.content = content
        self.actions = actions
        self.header = NSHostingView(rootView: PaneHeader(paneID: paneID, descriptor: descriptor,
                                                         currentKind: kind,
                                                         isFocused: false, canClose: true,
                                                         actions: actions))
        super.init(frame: .zero)

        // Two layers on purpose: a layer cannot both cast a shadow and clip its contents,
        // so the outer one lifts the pane off the material and the inner one rounds it.
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowColor = NSColor.black.cgColor

        clip.wantsLayer = true
        clip.layerContentsRedrawPolicy = .onSetNeedsDisplay
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true

        ring.isHidden = true

        // The tile's content lives INSIDE the glass, which is what `NSGlassEffectView`
        // expects — the material is the pane's surface, not a layer stacked behind it.
        glass.contentView = clip

        applyBackdrop()
        applyAppearance()

        header.focusRingType = .none
        addSubview(glass)
        clip.addSubview(content)
        clip.addSubview(header)
        clip.addSubview(dragHandle)
        addSubview(ring, positioned: .above, relativeTo: nil)
        refresh()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    /// Clicking ANYWHERE in a pane selects it, not just its header.
    ///
    /// `hitTest` is consulted during event dispatch, so gating on the current event narrows
    /// this to a real click rather than the cursor-rect and tracking passes that also call
    /// it. The event itself is passed through untouched, so the terminal still receives the
    /// click and text selection keeps working.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, !isFocused, NSApp.currentEvent?.type == .leftMouseDown {
            // Deferred: `hitTest` runs INSIDE event dispatch, and focusing writes to the
            // observable store, which drives a layout pass. Re-entering layout while the
            // window is still deciding which view got the click is how views get pulled out
            // from under an in-flight event.
            let id = paneID
            let focus = actions.focus
            DispatchQueue.main.async { focus(id) }
        }
        return hit
    }

    /// The band of the header you can pick the pane up by. Between the identity control on
    /// the left and the split cluster on the right, so all three keep their own gestures.
    private lazy var dragHandle = PaneDragHandleView(paneID: paneID) { [weak self] in
        self?.paneSnapshot()
    }

    /// A click on the handle that never became a drag is still a click on the header.
    func focusFromHandle() { actions.focus(paneID) }

    /// What the drag carries: the pane as it looks right now, at a size that reads as a
    /// thumbnail rather than as a second window being flung around.
    private func paneSnapshot() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let full = NSImage(size: bounds.size)
        full.addRepresentation(rep)
        let scale = min(1, 240 / max(bounds.width, 1))
        let size = CGSize(width: (bounds.width * scale).rounded(),
                          height: (bounds.height * scale).rounded())
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        full.draw(in: CGRect(origin: .zero, size: size),
                  from: .zero, operation: .copy, fraction: 0.85)
        thumb.unlockFocus()
        return thumb
    }

    private func refresh() {
        rebuildHeader()
        applyAppearance()
        applyLayerState()
    }

    /// Replace the header's SwiftUI root.
    ///
    /// Deliberately NOT called from `updateLayer`. AppKit calls that on every redraw, and
    /// assigning `rootView` makes SwiftUI lay out again, which can ask for another redraw —
    /// a loop AppKit reports as "AttributeGraph: cycle detected" and which leaves controls
    /// in the header unable to respond, the menu included.
    private func rebuildHeader() {
        header.rootView = PaneHeader(paneID: paneID, descriptor: descriptor, currentKind: kind,
                                     isFocused: isFocused, canClose: canClose, actions: actions,
                                     onIdentityTrailing: { [weak self] in
                                         self?.noteIdentityTrailing($0)
                                     })
    }

    /// Where the header's identity control ends, so the drag handle can start after it.
    ///
    /// A guess until the header has laid out once: close plus a short name. The header
    /// reports the real number on its first layout and on every rename after.
    private var identityTrailing: CGFloat = 72

    private func noteIdentityTrailing(_ x: CGFloat) {
        guard x != identityTrailing else { return }
        identityTrailing = x
        needsLayout = true
    }

    /// Colours that live on layers. Cheap, idempotent, and safe to re-run on every redraw.
    private func applyLayerState() {
        // Handed the accent as an `NSColor`, still dynamic: `PaneRingView` resolves it
        // against its OWN appearance, which is the only one that can be right for it.
        ring.tint = Token.Colour.focusBorder.nsColor
        ring.isHidden = !isFocused
        // Colour never carries a signal alone here: the focused pane also lifts, which is
        // what keeps focus legible for anyone who cannot separate the accent from grey.
        layer?.shadowOpacity = isFocused
            ? Token.Space.paneShadowOpacity * 1.6
            : Token.Space.paneShadowOpacity
    }

    /// What this pane's header was handed. Test seam: an empty kind list renders a menu
    /// that simply never opens, with no error anywhere.
    public var headerActionsForTesting: PaneActions { actions }

    /// What the pane is actually painting. Test seam: the opacity setting is only real if
    /// it is on the layer, and every pane's layer, not merely in the theme value.
    public var backdropColourForTesting: CGColor? { clip.layer?.backgroundColor }

    /// Where the header said its identity control ends. Test seam: the name is a control,
    /// and the number that keeps the drag handle off it has to be the measured one.
    public var identityTrailingForTesting: CGFloat { identityTrailing }

    /// The band a drag can start in. Test seam: a handle laid over the name would take the
    /// name's clicks, and nothing else in the layout would notice.
    public var dragHandleFrameForTesting: CGRect { dragHandle.frame }

    /// Where this pane sits in reading order, 1-based, or nil before layout has said.
    ///
    /// Announced because it is also the number that FOCUSES the pane: ⌘1…⌘9 count in the
    /// same order. Without it three shells in one directory announce identically and the
    /// only way to tell them apart is to move focus and listen for what changed.
    var accessibilityOrdinal: Int? {
        didSet { guard accessibilityOrdinal != oldValue else { return }; updateAccessibilityLabel() }
    }

    /// "2. Shell — ultra-swift" rather than "~/Repo/Ultra" three times over.
    ///
    /// The KIND leads because it is what distinguishes a pane from its neighbours far more
    /// often than the path does — a workspace is usually one directory and several kinds.
    private func updateAccessibilityLabel() {
        var parts: [String] = []
        if let accessibilityOrdinal { parts.append("\(accessibilityOrdinal).") }
        if let kind { parts.append(Self.name(of: kind)) }
        // A tile whose title merely repeats its kind — "Todo", "Ports" — says it once.
        if !descriptor.title.isEmpty,
           kind.map({ Self.name(of: $0).caseInsensitiveCompare(descriptor.title) != .orderedSame })
            ?? true {
            parts.append("— \(descriptor.title)")
        }
        setAccessibilityLabel(parts.joined(separator: " "))
    }

    /// Spoken names for the kinds. Deliberately NOT the raw case names: "fileTree" is read
    /// aloud as one word and lands somewhere between "filetree" and a spelling.
    private static func name(of kind: PaneRecord.Kind) -> String {
        switch kind {
        case .shell: "Shell"
        case .fileTree: "File Tree"
        case .editor: "Editor"
        case .todo: "Todo"
        case .ports: "Ports"
        case .resources: "Resources"
        case .git: "Git"
        case .context: "Context"
        case .chat: "Chat"
        case .placeholder: "Pane"
        }
    }

    /// Re-read the accent and repaint. See `PaneSurfaceStore.refreshChrome`.
    public func refreshChrome() { refresh() }

    /// Follow System flipped, or the app repinned itself. Layer colours were resolved once
    /// against the old appearance and will not re-resolve on their own.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerState()
    }

    /// A shell renames its own pane as it runs — a new cwd, a new foreground process.
    public func update(descriptor: PaneDescriptor) {
        guard descriptor != self.descriptor else { return }
        self.descriptor = descriptor
        updateAccessibilityLabel()
        refresh()
    }

    public override func layout() {
        super.layout()
        // Frames are assigned with implicit animation off — a pane must never lag the
        // cursor during a divider drag.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = bounds
        clip.frame = bounds
        let inset = Token.Space.focusRingInset
        ring.frame = bounds.insetBy(dx: inset, dy: inset)
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: Token.Space.paneRadius,
                                   cornerHeight: Token.Space.paneRadius,
                                   transform: nil)
        let headerHeight = Token.Space.tileHeaderHeight
        // A pane is header, content, footer — three elements, not one surface with chrome
        // floating on it. The content starts BELOW the header rather than running under it.
        //
        // Both of the earlier arrangements are why. Content under a see-through header meant
        // the grid scrolled up through the title; content under an OPAQUE header meant the
        // terminal theme's background painted as a slab of cold colour across the top of a
        // glass pane. With the band left to the pane's own surface there is nothing to show
        // through and no second colour: the header is a label on the pane's glass, and the
        // content simply stops where it stops.
        content.frame = CGRect(x: 0, y: min(headerHeight, bounds.height),
                               width: bounds.width,
                               height: max(0, bounds.height - headerHeight))
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
        // Between the identity control (close, icon and name, on the left) and the split
        // cluster. Both ends are controls, and a drag that starts on one of them is a
        // misfire — and the name is a control now, so its edge is measured, not assumed.
        let leadingGutter: CGFloat = identityTrailing + 2
        let trailingGutter: CGFloat = 68
        dragHandle.frame = CGRect(x: leadingGutter, y: 0,
                                  width: max(0, bounds.width - leadingGutter - trailingGutter),
                                  height: min(headerHeight, bounds.height))
        CATransaction.commit()
    }

    public override func updateLayer() { applyLayerState() }
}

#Preview("Pane header — focused", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "Ultra", subtitle: "~/Repo/Ultra"),
               currentKind: nil, isFocused: true, canClose: true, actions: .inert)
}

#Preview("Pane header — unfocused", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "Ultra", subtitle: "~/Repo/Ultra"),
               currentKind: nil, isFocused: false, canClose: true, actions: .inert)
}

#Preview("Pane header — last pane, no close", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(icon: "sparkles", title: "claude", subtitle: "agent"),
               currentKind: nil, isFocused: true, canClose: false, actions: .inert)
}

#Preview("Pane header — narrow", traits: .fixedLayout(width: 190, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "Ultra", subtitle: "~/Repo/Ultra"),
               currentKind: nil, isFocused: true, canClose: true, actions: .inert)
}

#Preview("Pane header — narrower than its name", traits: .fixedLayout(width: 140, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "ultra-swift-workspace", subtitle: "~/Repo/Ultra"),
               currentKind: nil, isFocused: true, canClose: true, actions: .inert)
}
