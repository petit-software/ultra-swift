import SwiftUI
import UltraDesign

/// A row's hover controls, floating OVER the row rather than laid out in it.
///
/// The rows in this module used to carry their controls as a trailing column that appeared
/// with the pointer — which cost the label its width the instant the pointer arrived, so
/// a long task re-wrapped and a truncated path moved its ellipsis under the hand reaching
/// for it. A row that moves under the pointer is a row you cannot aim at. An overlay takes
/// no part in layout: the row is the same shape hovered or not, and the controls sit on a
/// small pill of glass so three glyphs stay legible over whatever text runs beneath them.
///
/// Full label colour for the glyphs, not the tertiary grey a row's margin uses: these have
/// just appeared to be pressed, and grey on glass is a control that looks disabled. The
/// colour is dynamic, so the pill reads dark-on-light and light-on-dark alike.
public extension View {
    func tileHoverControls<Controls: View>(
        _ shown: Bool,
        alignment: Alignment = .trailing,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        overlay(alignment: alignment) {
            if shown {
                controls()
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Colour.label)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .tileHoverPill()
            }
        }
    }

    /// The pill under the controls: chrome floating over content, so glass — with the same
    /// opaque fallback under Reduce Transparency as every other piece of chrome.
    @ViewBuilder
    func tileHoverPill() -> some View {
        if Token.Environment_.reduceTransparency {
            background(Token.Colour.tileBackground, in: .capsule)
        } else {
            glassEffect(.regular, in: .capsule)
        }
    }
}
