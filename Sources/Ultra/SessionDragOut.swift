import AppKit
import SwiftUI
import UltraCanvas
import UltraCore
import UltraDesign

/// The session under the pointer once it has been dragged off the belt or out of the
/// sidebar.
///
/// Both draw a dragged session themselves while it is among the others, and both stop at
/// their own edge — the belt's scroll view clips, the sidebar's column ends. So away from
/// them the session is drawn in a small window of its own that follows the pointer
/// anywhere on screen, other displays included, which is also where it can be let go.
/// It takes no clicks and never the keyboard.
@MainActor
final class SessionDragGhost {
    static let shared = SessionDragGhost()

    private var panel: NSPanel?
    private var host: NSHostingView<Pill>?

    func show(title: String, symbol: String, tint: Color, at point: CGPoint) {
        let pill = Pill(title: title, symbol: symbol, tint: tint)
        let panel = self.panel ?? makePanel()
        if let host {
            host.rootView = pill
        } else {
            let host = NSHostingView(rootView: pill)
            panel.contentView = host
            self.host = host
        }
        let size = host?.fittingSize ?? CGSize(width: 160, height: 48)
        // Centred on the pointer: the tab has left its row, and where it was grabbed
        // along its length no longer says anything.
        panel.setFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// A tab as the belt draws one being dragged, with a window glyph trailing: letting
    /// go here makes a window of it.
    struct Pill: View {
        let title: String
        let symbol: String
        let tint: Color

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 16, height: 16)
                Text(title)
                    .foregroundStyle(Token.Colour.label)
                    .lineLimit(1)
                Image(systemName: "macwindow.badge.plus")
                    .foregroundStyle(Token.Colour.secondaryLabel)
            }
            .font(Token.Type_.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            // Room for the shadow, which the window would otherwise cut square.
            .padding(14)
            .fixedSize()
        }
    }
}

#Preview("Dragged-off tab", traits: .fixedLayout(width: 260, height: 80)) {
    SessionDragGhost.Pill(title: "ultra-swift", symbol: "shippingbox.fill", tint: .orange)
}
