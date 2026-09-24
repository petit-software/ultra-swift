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
/// the same icon and badge, and the same Customize sheet on a right-click. Reordering is
/// on File ▸ Session, and in the sidebar once it is shown again.
struct SessionTabBelt: View {
    @Bindable var sessions: SessionList
    /// For the customise flag, which File ▸ Session ▸ Customize Session… sets as well.
    @Bindable var ui: UIState
    /// What the selected tab's glass is matched through, so selecting another tab MOVES the
    /// capsule to it — one piece of glass sliding along the belt — instead of one fading
    /// out while another fades in.
    @Namespace private var glass

    var body: some View {
        // Scrolls rather than squeezes. A dozen sessions in a narrow window is the case a
        // sidebar was chosen for; here the tabs keep their names and the belt slides.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // The container is what lets the glass morph between tabs rather than being
                // torn down on one and built again on the next.
                GlassEffectContainer {
                    HStack(spacing: 2) {
                        ForEach(sessions.sessions, id: \.workspaceID) { store in
                            SessionTab(store: store,
                                       ui: ui,
                                       isSelected: sessions.selectedID == store.workspaceID,
                                       canClose: sessions.canCloseSelected,
                                       glass: glass,
                                       select: { sessions.select(store.workspaceID) },
                                       rename: { sessions.rename(store.workspaceID, to: $0) },
                                       close: { sessions.close(store.workspaceID) })
                                .id(store.workspaceID)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .animation(Token.Motion.structuralRespectingPreferences, value: sessions.selectedID)
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.never)
            // ⌥⌘] to a session scrolled out of sight should bring it into view — the keyboard
            // path changes the selection without ever touching the belt.
            .onChange(of: sessions.selectedID) { _, id in
                guard let id else { return }
                withAnimation(Token.Motion.structuralRespectingPreferences) {
                    proxy.scrollTo(id)
                }
            }
        }
        .frame(height: Token.Space.tileHeaderHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }
}

/// One session on the belt: its icon, its name, and the one trailing slot a sidebar row has.
private struct SessionTab: View {
    let store: LayoutStore
    @Bindable var ui: UIState
    let isSelected: Bool
    let canClose: Bool
    let glass: Namespace.ID
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    @State private var isHovering = false
    /// Seeded from disk, and moved by the Customize sheet — the same arrangement as a
    /// sidebar row, so the tab wears a new icon the moment it is picked.
    @State private var appearance: SessionAppearance

    init(store: LayoutStore, ui: UIState, isSelected: Bool, canClose: Bool,
         glass: Namespace.ID, select: @escaping () -> Void,
         rename: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.store = store
        self.ui = ui
        self.isSelected = isSelected
        self.canClose = canClose
        self.glass = glass
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

    /// Off the monitor, which is `@Observable`, the same as a sidebar row.
    private var status: AgentStatus {
        AgentMonitor.shared.statusBySession[store.workspaceID] ?? .idle
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: SessionSymbols.resolved(appearance.symbol))
                .font(Token.Type_.body.weight(.semibold))
                .foregroundStyle(SessionTint(storedValue: appearance.tint).color)
                .frame(width: 16)

            // Semibold in BOTH states. Selection is carried by the glass capsule and the label
            // colour; a weight change as well made the selected tab wider than it was a
            // moment ago, and every tab after it slid along the belt on each switch.
            Text(store.workspaceTitle)
                .font(Token.Type_.body)
                .fontWeight(.semibold)
                .foregroundStyle(isSelected ? Token.Colour.label : Token.Colour.secondaryLabel)
                .lineLimit(1)

            // The sidebar row's rule: one slot of a fixed width, close on the hovered or
            // selected tab, the agent badge otherwise — so a status light never shifts as
            // the pointer crosses it.
            ZStack {
                if isSelected || isHovering, canClose {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isHovering ? AnyShapeStyle(Token.Colour.label)
                                                : AnyShapeStyle(.secondary))
                    .help("Close session")
                } else if let badge = status.badge {
                    Image(systemName: badge.symbol)
                        .foregroundStyle(badge.colour)
                        .symbolEffect(.pulse, isActive: status == .working)
                        .help(badge.help)
                }
            }
            .font(Token.Type_.body)
            .frame(width: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        // The selected tab sits in a glass capsule; the rest sit on the window's material,
        // with a faint wash under the pointer. The belt is chrome — the navigation layer —
        // which is the one place glass belongs in this app.
        .background {
            if !isSelected, isHovering {
                Capsule().fill(Token.Colour.selectionWash.opacity(0.5))
            }
        }
        .modifier(SelectedGlass(isSelected: isSelected, glass: glass))
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        // A tap rather than a `Button` so the close button inside keeps its own click.
        // The keyboard path is ⌥⌘[ / ⌥⌘] (Next / Previous Session), which is the point of
        // the belt being a view of the session list rather than a control of its own.
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
        .accessibilityLabel(status.badge.map { "Session, \(store.workspaceTitle), \($0.help)" }
                            ?? "Session, \(store.workspaceTitle)")
        .accessibilityAction { select() }
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
