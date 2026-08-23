import SwiftUI

/// The icon control worn by a tile's chrome — pane header and tile footer alike.
///
/// One type because there were two: a header button at 15pt semibold in a 28×26 box with a
/// hover plate, and a footer button at 12pt medium in an 18×16 box with none. They were
/// meant to be the same control, so every time one was touched the pair drifted a little
/// further apart. The size and the hover treatment now have exactly one definition.
public struct ChromeIconLabel: View {
    /// The standard glyph size. Chevrons and other tall-reading symbols pass their own.
    public static let size: CGFloat = 15
    /// Wider than it is tall: icons sit in a row, and a square box packs them too tightly
    /// to aim at while a wide one keeps the row on an even rhythm.
    public static let width: CGFloat = 28
    public static let height: CGFloat = 26

    let symbol: String
    var size: CGFloat = ChromeIconLabel.size
    var isHovering = false
    var isDestructive = false
    /// Overrides the RESTING colour only. A pane's own icon carries the app tint when its
    /// pane is focused, and that identity has to survive the icon becoming pressable —
    /// otherwise making it a control would quietly cost the focused pane its accent.
    /// Hover still brightens to `label`, so every chrome icon answers the pointer alike.
    var tint: Color?

    public init(symbol: String, size: CGFloat = ChromeIconLabel.size,
                isHovering: Bool = false, isDestructive: Bool = false,
                tint: Color? = nil) {
        self.symbol = symbol
        self.size = size
        self.isHovering = isHovering
        self.isDestructive = isDestructive
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .frame(width: Self.width, height: Self.height)
            .contentShape(.rect)
            .foregroundStyle(isHovering
                             ? (isDestructive ? Color.red : Token.Colour.label)
                             : (tint ?? Token.Colour.secondaryLabel))
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Token.Colour.label.opacity(0.10))
                }
            }
    }
}

/// A pressable `ChromeIconLabel`.
///
/// Split from its label so a `Menu` can wear the same chrome a `Button` does — a folder menu
/// in a footer has to be indistinguishable from the buttons beside it, and a Menu cannot be
/// wrapped in a Button to get there.
public struct ChromeIconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = ChromeIconLabel.size
    var isDestructive = false
    var isEnabled = true
    var tint: Color?
    let action: () -> Void

    @State private var isHovering = false

    public init(symbol: String, help: String, size: CGFloat = ChromeIconLabel.size,
                isDestructive: Bool = false, isEnabled: Bool = true,
                tint: Color? = nil,
                action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.size = size
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ChromeIconLabel(symbol: symbol, size: size,
                            isHovering: isHovering, isDestructive: isDestructive,
                            tint: tint)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // A disabled control dims rather than disappearing: one that vanishes takes its own
        // affordance with it, and nobody learns a button that is not there.
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        // The shortcut lives in the tooltip, so the control teaches its key rather than
        // replacing it.
        .help(help)
        .accessibilityLabel(help)
    }
}
