import AppKit
import SwiftUI
import UltraDesign
import UltraLayout

/// A control in the window bar. Every one mirrors a menu command — the bar is a *view* of
/// the command registry, never a second way to do something.
public struct WindowBarAction: Identifiable {
    public let id: String
    public let symbol: String
    public let help: String
    public let run: () -> Void

    public init(id: String, symbol: String, help: String, run: @escaping () -> Void) {
        self.id = id
        self.symbol = symbol
        self.help = help
        self.run = run
    }
}

/// The window bar: what this window is, and the few controls worth having at the top level.
///
/// It sits in the transparent titlebar over the same backdrop material as the canvas, so
/// the window reads as one continuous surface with the panes floating on it.
public struct WindowTitleBar: View {
    let title: String
    let subtitle: String?
    let isZoomed: Bool
    let actions: [WindowBarAction]

    /// The system's real traffic lights own the leading corner; nothing goes under them.
    /// Derived from where they are actually placed, so moving them moves this too.
    private var trafficLightGutter: CGFloat {
        Token.Space.trafficLightInset + 2 * Token.Space.trafficLightSpacing + 22
    }

    public init(title: String, subtitle: String?, isZoomed: Bool, actions: [WindowBarAction]) {
        self.title = title
        self.subtitle = subtitle
        self.isZoomed = isZoomed
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: trafficLightGutter, height: 1)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Token.Colour.label)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if isZoomed {
                // Zoom hides every other pane. Without a marker, a user who triggered it by
                // accident just sees their layout gone.
                Label("Zoomed", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Token.Colour.accent.opacity(0.18), in: .capsule)
                    .foregroundStyle(Token.Colour.accent)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                ForEach(actions) { action in
                    PaneHeaderButton(symbol: action.symbol, help: action.help, action: action.run)
                }
            }
            .fixedSize()
        }
        .padding(.trailing, 8)
        .frame(height: Token.Space.titleBarHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window bar, \(title)")
    }
}

#Preview("Window bar", traits: .fixedLayout(width: 700, height: 40)) {
    WindowTitleBar(title: "ultra-swift", subtitle: "~/Repo/ultra-swift", isZoomed: false,
                   actions: [
                    WindowBarAction(id: "a", symbol: "square.split.2x1", help: "Split Right") {},
                    WindowBarAction(id: "b", symbol: "magnifyingglass", help: "Commands") {},
                   ])
    .background(Token.Colour.tileBackground)
}

#Preview("Window bar — zoomed", traits: .fixedLayout(width: 700, height: 40)) {
    WindowTitleBar(title: "ultra-swift", subtitle: "~/Repo/ultra-swift", isZoomed: true,
                   actions: [WindowBarAction(id: "b", symbol: "magnifyingglass", help: "Commands") {}])
    .background(Token.Colour.tileBackground)
}
