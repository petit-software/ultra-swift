import SwiftUI
import UltraDesign

public extension View {
    /// Leave room for the pane header, which floats OVER a tile rather than sitting above it.
    ///
    /// `safeAreaInset` rather than padding on purpose: a scroll view then starts its content
    /// below the header but still DRAWS through it, which is the whole point — the header's
    /// blur needs something moving underneath to be worth having.
    func tileHeaderInset() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: Token.Space.tileHeaderHeight)
        }
    }
}
