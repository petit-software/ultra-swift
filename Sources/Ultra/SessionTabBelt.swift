import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign
import UltraTerminal

/// The window's sessions as a row of tabs under the tiles, for a window whose sidebar is
/// collapsed.
///
/// Collapsing the sidebar used to take the sessions off screen altogether: the only sign
/// that the window held more than one project was ⌥⌘] landing somewhere else. The belt
/// puts them back without giving the column back — one strip, the height of a pane header,
/// inside the same padding the tiles sit in, so it reads as part of the canvas rather than
/// as a bar bolted to the window's edge.
///
/// A VIEW of the sidebar, not a second list: the same `SessionList`, the same selection,
/// the same icon, and the same Customize sheet on a right-click. No agent badge: the belt
/// names sessions, and the sidebar is where their agents are watched. Reordering is
/// by dragging a tab along the belt, and on File ▸ Session ▸ Move Session Up / Down.
struct SessionTabBelt: View {
    @Bindable var sessions: SessionList
    /// For the customise flag, which File ▸ Session ▸ Customize Session… sets as well.
    @Bindable var ui: UIState
    /// What the selected tab's glass is matched through, so selecting another tab MOVES the
    /// capsule to it — one piece of glass sliding along the belt — instead of one fading
    /// out while another fades in.
    @Namespace private var glass

    // MARK: Dragging
    //
    // A drag gesture inside the belt, not system drag and drop. The pasteboard carried the
    // tab as text, which a terminal pane took as typing; the drop delegates never said when a
    // drag was cancelled; and nothing could put a tab back. Here the belt owns the whole
    // drag: where the tab is, where it would land (`TabStripReorder`, pure and tested), and
    // whether it lands at all. The order is written once, on release.

    /// Each tab's width as last laid out, which is what the landing arithmetic runs on.
    @State private var widths: [UUID: CGFloat] = [:]
    @State private var drag: TabDrag?
    /// Escape cancelled a drag the pointer is still holding. The rest of that gesture is
    /// ignored, so moving the pointer again does not pick the tab back up.
    @State private var dragCancelled = false
    @State private var escapeMonitor: EventMonitor?
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var scrollX: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private static let spacing: CGFloat = 2
    private static let inset: CGFloat = 4
    /// How close to the belt's end the pointer has to be to scroll it.
    private static let autoscrollEdge: CGFloat = 28
    /// How far above or below the belt a release still counts as a drop.
    private static let releaseMargin: CGFloat = 24
    private static let height = Token.Space.tileHeaderHeight + 6
    private static let viewport = "session-belt"

    var body: some View {
        // Scrolls rather than squeezes. A dozen sessions in a narrow window is the case a
        // sidebar was chosen for; here the tabs keep their names and the belt slides.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // The container is what lets the glass morph between tabs rather than being
                // torn down on one and built again on the next.
                GlassEffectContainer {
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(sessions.sessions.enumerated()), id: \.element.workspaceID) {
                            index, store in
                            tab(store, at: index)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                }
                .animation(Token.Motion.structuralRespectingPreferences, value: sessions.selectedID)
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                scrollX = x
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, width in
                viewportWidth = width
            }
            .coordinateSpace(.named(Self.viewport))
            // Near an end, the belt scrolls under the dragged tab, so a tab can be taken past
            // the ones out of sight. Restarted whenever the direction changes; a no-op at 0.
            .task(id: autoscrollDirection) { await autoscroll() }
            // ⌥⌘] to a session scrolled out of sight should bring it into view — the keyboard
            // path changes the selection without ever touching the belt.
            .onChange(of: sessions.selectedID) { _, id in
                guard let id else { return }
                withAnimation(Token.Motion.structuralRespectingPreferences) {
                    proxy.scrollTo(id)
                }
            }
        }
        // 6pt taller than a pane header, for tabs 6pt taller than they were.
        .frame(height: Self.height)
        .onDisappear { endEscapeMonitor() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private func tab(_ store: LayoutStore, at index: Int) -> some View {
        let id = store.workspaceID
        return SessionTab(store: store,
                          ui: ui,
                          isSelected: sessions.selectedID == id,
                          canClose: sessions.canCloseSelected,
                          glass: glass,
                          mode: mode(of: index, id: id),
                          select: { sessions.select(id) },
                          rename: { sessions.rename(id, to: $0) },
                          close: { ui.closingSessionID = id })
            .id(id)
            .zIndex(drag?.id == id ? 1 : 0)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in
                widths[id] = width
            }
            // Four points before it is a drag, so a click is still a click.
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.viewport))
                .onChanged { value in dragChanged(id, value) }
                .onEnded { value in dragEnded(value) })
    }

    // MARK: - Drag state

    /// The strip as laid out, or nil until every tab has been measured.
    private var strip: TabStripReorder? {
        let measured = sessions.sessions.compactMap { widths[$0.workspaceID] }
        guard measured.count == sessions.sessions.count else { return nil }
        return TabStripReorder(widths: measured, spacing: Self.spacing, leading: Self.inset)
    }

    /// Where the dragged tab's leading edge is, in the strip's content coordinates.
    private func draggedMinX(_ drag: TabDrag, in strip: TabStripReorder) -> CGFloat {
        strip.clampedMinX(drag.pointerX + scrollX - drag.grab, dragging: drag.from)
    }

    private func mode(of index: Int, id: UUID) -> SessionTab.DragMode {
        guard let drag, let strip else { return .resting(shift: 0) }
        let x = draggedMinX(drag, in: strip)
        let to = strip.destination(dragging: drag.from, minX: x)
        if drag.id == id {
            return .dragged(slot: strip.slotOffset(dragging: drag.from, to: to),
                            float: x - strip.minX(of: drag.from))
        }
        return .resting(shift: strip.shift(of: index, dragging: drag.from, to: to))
    }

    private var autoscrollDirection: Int {
        guard let drag else { return 0 }
        return TabStripReorder.autoscrollDirection(pointerX: drag.pointerX,
                                                   viewportWidth: viewportWidth,
                                                   edge: Self.autoscrollEdge)
    }

    private func autoscroll() async {
        let direction = CGFloat(autoscrollDirection)
        guard direction != 0 else { return }
        while !Task.isCancelled, drag != nil, let strip {
            let limit = max(0, strip.contentWidth - viewportWidth)
            let next = min(max(scrollX + direction * 6, 0), limit)
            guard next != scrollX else { return }
            scrollPosition.scrollTo(x: next)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    // MARK: - Drag events

    private func dragChanged(_ id: UUID, _ value: DragGesture.Value) {
        guard !dragCancelled else { return }
        if drag != nil {
            drag?.pointerX = value.location.x
            return
        }
        guard let strip,
              let from = sessions.sessions.firstIndex(where: { $0.workspaceID == id }) else { return }
        drag = TabDrag(id: id, from: from,
                       grab: value.startLocation.x + scrollX - strip.minX(of: from),
                       pointerX: value.location.x)
        beginEscapeMonitor()
    }

    /// Let go on the belt, or near it: the tab lands. Well above or below it: it goes back,
    /// the way a tab dragged off Safari's bar and dropped nowhere does.
    private func dragEnded(_ value: DragGesture.Value) {
        defer { dragCancelled = false }
        guard !dragCancelled, drag != nil else { return }
        let y = value.location.y
        let onBelt = y > -Self.releaseMargin && y < Self.height + Self.releaseMargin
        finishDrag(commit: onBelt)
    }

    private func finishDrag(commit: Bool) {
        endEscapeMonitor()
        guard let drag else { return }
        withAnimation(Token.Motion.structuralRespectingPreferences) {
            if commit, let strip {
                let to = strip.destination(dragging: drag.from, minX: draggedMinX(drag, in: strip))
                if to != drag.from {
                    sessions.move(fromOffsets: [drag.from],
                                  toOffset: TabStripReorder.moveOffset(from: drag.from, to: to))
                }
            }
            self.drag = nil
        }
    }

    /// Escape puts the tab back. A local monitor rather than a key handler, because the
    /// keyboard is in a terminal pane during a drag and would otherwise get the Escape.
    private func beginEscapeMonitor() {
        endEscapeMonitor()
        escapeMonitor = EventMonitor { [self] in
            dragCancelled = true
            finishDrag(commit: false)
        }
    }

    private func endEscapeMonitor() {
        escapeMonitor?.stop()
        escapeMonitor = nil
    }
}

/// A tab on its way along the belt.
private struct TabDrag: Equatable {
    let id: UUID
    /// Its index when the drag began. The list is not touched until release.
    let from: Int
    /// Where the pointer took hold of it, from its leading edge.
    let grab: CGFloat
    /// The pointer, in the belt's viewport — not its content, which scrolls.
    var pointerX: CGFloat
}

/// Swallows Escape while a tab is being dragged, and reports it.
@MainActor
private final class EventMonitor {
    private var token: Any?

    init(onEscape: @escaping @MainActor () -> Void) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { onEscape() }
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// One session on the belt: its icon and its name. Under the pointer, the icon slot holds
/// the close button instead, so closing costs no width and nothing shifts.
private struct SessionTab: View {
    let store: LayoutStore
    @Bindable var ui: UIState
    let isSelected: Bool
    let canClose: Bool
    let glass: Namespace.ID
    let mode: DragMode
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    @State private var isHovering = false

    /// Where a tab is while the belt is being reordered. Offsets only: the list is not
    /// touched until the drag ends, so nothing is laid out again on every pointer move.
    enum DragMode: Equatable {
        /// Moved aside by `shift` to open the gap the dragged tab will land in.
        case resting(shift: CGFloat)
        /// The dragged tab: its empty slot `slot` from where it started, and the tab itself
        /// `float` from there, under the pointer.
        case dragged(slot: CGFloat, float: CGFloat)
    }
    /// Seeded from disk, and moved by the Customize sheet — the same arrangement as a
    /// sidebar row, so the tab wears a new icon the moment it is picked.
    @State private var appearance: SessionAppearance

    init(store: LayoutStore, ui: UIState, isSelected: Bool, canClose: Bool,
         glass: Namespace.ID, mode: DragMode, select: @escaping () -> Void,
         rename: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.store = store
        self.ui = ui
        self.isSelected = isSelected
        self.canClose = canClose
        self.glass = glass
        self.mode = mode
        self.select = select
        self.rename = rename
        self.close = close
        _appearance = State(initialValue: SessionAppearanceStore.appearance(
            forDirectory: store.workspaceDirectory))
    }

    private var defaultName: String {
        store.workspaceDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? store.workspaceTitle
    }

    /// The window-level flag, answered by the tab it NAMES and only while the belt is the
    /// list on screen — the sidebar's row answers it otherwise.
    private var isCustomizing: Binding<Bool> {
        Binding(get: { ui.showsTabBelt && ui.customizingSessionID == store.workspaceID },
                set: { ui.customizingSessionID = $0 ? store.workspaceID : nil })
    }

    private var name: Binding<String> {
        Binding(get: { store.workspaceTitle }, set: { rename($0) })
    }

    private var isPlaceholder: Bool {
        if case .dragged = mode { return true }
        return false
    }

    /// Resting tabs slide aside by their shift; the dragged tab's empty slot sits at the
    /// landing place. Both animate, so the gap opens rather than jumps.
    private var baseOffset: CGFloat {
        switch mode {
        case .resting(let shift): shift
        case .dragged(let slot, _): slot
        }
    }

    var body: some View {
        label(showsClose: isHovering && !isPlaceholder)
            // The dragged tab's place: the same size, nothing in it. The icon and name are
            // under the pointer; showing them here as well said the tab was in two places.
            .opacity(isPlaceholder ? 0 : 1)
            // The selected tab sits in a glass capsule; the rest sit on the window's
            // material, with a faint wash under the pointer. The belt is chrome — the
            // navigation layer — which is the one place glass belongs in this app.
            .background {
                if isPlaceholder {
                    Capsule().fill(Token.Colour.label.opacity(0.1))
                } else if !isSelected, isHovering {
                    Capsule().fill(Token.Colour.selectionWash.opacity(0.5))
                }
            }
            .modifier(SelectedGlass(isSelected: isSelected && !isPlaceholder, glass: glass))
            .offset(x: baseOffset)
            .animation(Token.Motion.structuralRespectingPreferences, value: baseOffset)
            // The tab itself, following the pointer. After the animation, so it tracks the
            // pointer exactly instead of easing after it; the overlay sits on the tab's
            // starting frame, which is what `float` is measured from.
            .overlay(alignment: .leading) {
                if case .dragged(_, let float) = mode {
                    label(showsClose: false)
                        .background(.regularMaterial, in: .capsule)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                        .offset(x: float)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            // A tap rather than a `Button` so the close button inside keeps its own click.
            // The keyboard path is ⌥⌘[ / ⌥⌘] (Next / Previous Session), which is the point
            // of the belt being a view of the session list rather than a control of its own.
            .onTapGesture(perform: select)
            .help(store.workspaceSubtitle ?? store.workspaceTitle)
            // Right-click, the sidebar row's menu: the same two verbs, both also on File ▸
            // Session. Customize selects too, so the session behind the sheet is this one.
            .contextMenu {
                Button("Customize") {
                    select()
                    ui.customizingSessionID = store.workspaceID
                }
                .disabled(store.workspaceDirectory == nil)
                if canClose {
                    Divider()
                    Button("Close Session", action: close)
                }
            }
            .sessionCustomizer(isPresented: isCustomizing, store: store, name: name,
                               appearance: $appearance,
                               defaultName: defaultName, rename: rename)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("Session, \(store.workspaceTitle)")
            .accessibilityAction { select() }
    }

    /// The icon and the name, padded to a tab's size. Shared by the tab and its drag preview,
    /// so what is under the pointer is the tab that left the belt.
    private func label(showsClose: Bool) -> some View {
        HStack(spacing: 7) {
            // One slot, two occupants: the session's icon, or — under the pointer — the X.
            // Both 16pt wide, so the name never moves as the pointer crosses the tab.
            ZStack {
                if showsClose, canClose {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 16, height: 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.label)
                    .help("Close session")
                } else {
                    Image(systemName: SessionSymbols.resolved(appearance.symbol))
                        .foregroundStyle(SessionTint(storedValue: appearance.tint).color)
                }
            }
            .font(Token.Type_.body.weight(.semibold))
            // A fixed box in BOTH directions. Width alone let the X, shorter than most
            // session symbols, change the tab's height — and the belt shifted on hover.
            .frame(width: 16, height: 16)

            // Semibold in BOTH states. Selection is carried by the glass capsule and the label
            // colour; a weight change as well made the selected tab wider than it was a
            // moment ago, and every tab after it slid along the belt on each switch.
            Text(store.workspaceTitle)
                .font(Token.Type_.body)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)
        }
        // As wide as its name: no minimum, so a short name makes a short tab. 6pt taller
        // than before (5 → 8 each side).
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The selected tab's capsule. Glass with an id, so it morphs from tab to tab inside the
/// belt's `GlassEffectContainer`; under Reduce Transparency, the neutral wash `PillTabs`
/// uses, which says "selected" without a material.
private struct SelectedGlass: ViewModifier {
    let isSelected: Bool
    let glass: Namespace.ID

    func body(content: Content) -> some View {
        if !isSelected {
            content
        } else if Token.Environment_.reduceTransparency {
            content.background(Token.Colour.selectionWash, in: .capsule)
        } else {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("selected", in: glass)
        }
    }
}

#Preview("Session tab belt", traits: .fixedLayout(width: 700, height: 60)) {
    SessionTabBelt(sessions: SessionList(storage: WorkspaceStorage(),
                                         adopting: [.placeholders(.threeAcross),
                                                    .placeholders(.grid2x2),
                                                    .placeholders(.single)]),
                   ui: UIState())
        .padding(8)
}
