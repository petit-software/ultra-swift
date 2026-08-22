import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// What a pane's chrome can do. Every one of these is also a menu command with a key
/// equivalent — a pointer affordance without a keyboard equivalent is a bug, see the
/// `keyboard-first` skill.
@MainActor
public struct PaneActions {
    public var split: (PaneID, UltraLayout.Edge) -> Void
    public var close: (PaneID) -> Void
    public var focus: (PaneID) -> Void

    public init(split: @escaping (PaneID, UltraLayout.Edge) -> Void,
                close: @escaping (PaneID) -> Void,
                focus: @escaping (PaneID) -> Void) {
        self.split = split
        self.close = close
        self.focus = focus
    }

    public static let inert = PaneActions(split: { _, _ in }, close: { _ in }, focus: { _ in })
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

/// A pane's header: identity on the left, explicit split and close controls on the right.
///
/// Glass, because it is the tile's navigation layer sitting above opaque content — never
/// the other way round. See docs/02-DESIGN-LANGUAGE.md.
public struct PaneHeader: View {
    let paneID: PaneID
    let descriptor: PaneDescriptor
    let isFocused: Bool
    let canClose: Bool
    let actions: PaneActions

    @State private var isHovering = false

    private var icon: some View {
        Image(systemName: descriptor.icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isFocused ? Token.Colour.accent : Token.Colour.tertiaryLabel)
    }

    private func identity(showSubtitle: Bool) -> some View {
        HStack(spacing: 6) {
            icon
            Text(descriptor.title)
                .font(Token.Type_.tileTitle)
                .foregroundStyle(isFocused ? Token.Colour.label : Token.Colour.secondaryLabel)
                .fixedSize()
            if showSubtitle, let subtitle = descriptor.subtitle {
                Text(subtitle)
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .fixedSize()
            }
        }
    }

    public var body: some View {
        HStack(spacing: 6) {
            // A head-truncated subtitle reading "…t" is worse than no subtitle, so drop
            // parts of the identity as the pane narrows rather than mangling them.
            ViewThatFits(in: .horizontal) {
                identity(showSubtitle: true)
                identity(showSubtitle: false)
                icon
            }

            Spacer(minLength: 4)

            HStack(spacing: 1) {
                PaneHeaderButton(symbol: "square.split.2x1", help: "Split Right (⌘D)") {
                    actions.split(paneID, .right)
                }
                PaneHeaderButton(symbol: "square.split.1x2", help: "Split Down (⇧⌘D)") {
                    actions.split(paneID, .bottom)
                }
                if canClose {
                    PaneHeaderButton(symbol: "xmark", help: "Close Pane (⌘W)", isDestructive: true) {
                        actions.close(paneID)
                    }
                }
            }
            // Always present, so the affordance is discoverable rather than hidden behind a
            // hover the user has to find. Hovering just brings them forward.
            .opacity(isHovering ? 1 : (isFocused ? 0.72 : 0.4))
            .fixedSize()
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: Token.Space.tileHeaderHeight)
        .frame(maxWidth: .infinity)
        // No background at all. The header is not a bar and not a separate surface: it is
        // a label floating on the pane's own glass, in the same material as the terminal
        // beneath it. Anything drawn here re-introduces the seam.
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .onTapGesture { actions.focus(paneID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(descriptor.subtitle.map { "\(descriptor.title), \($0)" }
                            ?? descriptor.title)
    }
}

struct PaneHeaderButton: View {
    let symbol: String
    let help: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering
                         ? (isDestructive ? Color.red : Token.Colour.label)
                         : Token.Colour.secondaryLabel)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Token.Colour.label.opacity(0.10))
            }
        }
        .onHover { isHovering = $0 }
        // The shortcut is in the tooltip so the control teaches its key, not replaces it.
        .help(help)
        .accessibilityLabel(help)
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
    private let clip = FlippedView()
    private let header: NSHostingView<PaneHeader>
    private var descriptor: PaneDescriptor
    private let actions: PaneActions

    public var isFocused: Bool = false {
        didSet { guard isFocused != oldValue else { return }; refresh() }
    }


    /// The close control disappears when a pane is the last one — there is nothing to
    /// close back to.
    public var canClose: Bool = true {
        didSet { guard canClose != oldValue else { return }; refresh() }
    }

    public init(paneID: PaneID, descriptor: PaneDescriptor, content: NSView, actions: PaneActions) {
        self.paneID = paneID
        self.descriptor = descriptor
        self.content = content
        self.actions = actions
        self.header = NSHostingView(rootView: PaneHeader(paneID: paneID, descriptor: descriptor,
                                                         isFocused: false, canClose: true,
                                                         actions: actions))
        super.init(frame: .zero)

        // Two layers on purpose: a layer cannot both cast a shadow and clip its contents,
        // so the outer one lifts the pane off the material and the inner one rounds it.
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowRadius = Token.Space.paneShadowRadius
        layer?.shadowOpacity = Token.Space.paneShadowOpacity
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        layer?.shadowColor = NSColor.black.cgColor

        clip.wantsLayer = true
        clip.layerContentsRedrawPolicy = .onSetNeedsDisplay
        clip.layer?.cornerRadius = Token.Space.paneRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 1

        // The tile's content lives INSIDE the glass, which is what `NSGlassEffectView`
        // expects — the material is the pane's surface, not a layer stacked behind it.
        glass.cornerRadius = Token.Space.paneRadius
        glass.contentView = clip

        header.focusRingType = .none
        addSubview(glass)
        clip.addSubview(content)
        clip.addSubview(headerBlur)
        clip.addSubview(header)
        refresh()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(descriptor.title)
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

    /// A blur that ramps in from nothing at its bottom edge to full at the top.
    ///
    /// The pane title has no background of its own, so content scrolling up behind it would
    /// otherwise collide with the text. A hard-edged material bar would be a background by
    /// another name; ramping the material's own opacity keeps the header reading as part of
    /// the pane's surface while still separating the words from whatever slides under them.
    private let headerBlur = HeaderBlurView()

    private func refresh() {
        header.rootView = PaneHeader(paneID: paneID, descriptor: descriptor,
                                     isFocused: isFocused, canClose: canClose, actions: actions)
        // An unfocused pane wears no border at all — depth already separates it. Drawing a
        // box around every pane is what made six panes read as six grey slabs.
        clip.layer?.borderColor = isFocused
            ? Token.Colour.focusBorder.nsColor.cgColor
            : NSColor.clear.cgColor
        // Colour alone must never carry the signal, so the focused pane also lifts higher.
        layer?.shadowOpacity = isFocused
            ? Token.Space.paneShadowOpacity * 1.6
            : Token.Space.paneShadowOpacity
    }

    /// The corner radius the pane's clip layer is actually using. Test seam: the whole
    /// failure mode here is a setting that changes the number but not the pixels.
    public var appliedCornerRadius: CGFloat { clip.layer?.cornerRadius ?? 0 }

    /// Re-apply every appearance token this view caches in layer state.
    public func refreshAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowRadius = Token.Space.paneShadowRadius
        glass.cornerRadius = Token.Space.paneRadius
        clip.layer?.cornerRadius = Token.Space.paneRadius
        CATransaction.commit()
        headerBlur.refreshAppearance()
        refresh()
        needsLayout = true
    }

    /// A shell renames its own pane as it runs — a new cwd, a new foreground process.
    public func update(descriptor: PaneDescriptor) {
        guard descriptor != self.descriptor else { return }
        self.descriptor = descriptor
        setAccessibilityLabel(descriptor.title)
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
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: Token.Space.paneRadius,
                                   cornerHeight: Token.Space.paneRadius,
                                   transform: nil)
        let headerHeight = Token.Space.tileHeaderHeight
        // The content fills the WHOLE pane, header included, and the header floats on top of
        // it. Previously the content began below the header, which left that band showing the
        // pane's glass — a second surface behind the title, exactly what a shell pane does
        // not have. Content is what the header's blur has to blur, so it has to be under it.
        content.frame = bounds
        headerBlur.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                  height: min(headerHeight, bounds.height))
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
        CATransaction.commit()
    }

    public override func updateLayer() { refresh() }
}

#Preview("Pane header — focused", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "ultra-swift", subtitle: "~/Repo/ultra-swift"),
               isFocused: true, canClose: true, actions: .inert)
}

#Preview("Pane header — unfocused", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "ultra-swift", subtitle: "~/Repo/ultra-swift"),
               isFocused: false, canClose: true, actions: .inert)
}

#Preview("Pane header — last pane, no close", traits: .fixedLayout(width: 420, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(icon: "sparkles", title: "claude", subtitle: "agent"),
               isFocused: true, canClose: false, actions: .inert)
}

#Preview("Pane header — narrow", traits: .fixedLayout(width: 190, height: 40)) {
    PaneHeader(paneID: LayoutTree.fixturePane(1),
               descriptor: PaneDescriptor(title: "ultra-swift", subtitle: "~/Repo/ultra-swift"),
               isFocused: true, canClose: true, actions: .inert)
}
