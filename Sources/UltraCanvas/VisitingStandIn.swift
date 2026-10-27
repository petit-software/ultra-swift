import SwiftUI
import UltraDesign

/// What a canvas shows where a pane is while the pane is away on loan — on the Agents
/// overview, which gathers every agent's pane onto one canvas (`PaneSurfaceStore.lend`).
///
/// The pane's own header stays above this, so the canvas keeps its shape and its names;
/// only the content says where the pane has gone. Quiet on purpose: a stand-in that drew
/// attention to itself would make every pane a visitor had borrowed read as broken.
struct VisitingStandIn: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text("Showing in Agents")
                .font(Token.Type_.tileTitle)
                .foregroundStyle(Token.Colour.secondaryLabel)
            Text("⌘0 to see it there, or close the overview to bring it back")
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), showing in the Agents overview")
    }
}

#Preview("Stand-in", traits: .fixedLayout(width: 420, height: 240)) {
    VisitingStandIn(title: "claude")
        .background(Token.Colour.tileBackground)
}
