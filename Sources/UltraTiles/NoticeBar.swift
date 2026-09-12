import SwiftUI
import UltraDesign

/// The strip a tile shows along its top when something happened to its file: reloaded,
/// changed underneath an edit, could not be saved.
///
/// One view for every tile rather than a copy per tile, so the Todo strip and the Editor
/// strip cannot drift apart in their padding, their type, or where the close control sits.
///
/// A FILLED symbol on the left, because the strip is small type on a tinted band and an
/// outlined glyph at that size reads as a smudge. An `⌫`-shaped close control on the right,
/// where every dismiss control on the Mac lives, rather than the word "Dismiss" — a notice
/// is a one-line aside, and a word-sized button made it read as a dialog. Anything the
/// notice offers beyond closing — a Reload, say — goes in `actions`, between the message
/// and the close control.
struct NoticeBar<Actions: View>: View {
    let symbol: String
    let message: String
    /// The band behind the strip. The accent wash by default; a notice that needs a
    /// decision, like an edit conflict, passes a warmer one so it does not read as routine.
    var tint: Color = Token.Colour.accentWash
    let dismiss: () -> Void
    @ViewBuilder var actions: () -> Actions

    init(symbol: String,
         message: String,
         tint: Color = Token.Colour.accentWash,
         dismiss: @escaping () -> Void,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.message = message
        self.tint = tint
        self.dismiss = dismiss
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(message).lineLimit(2)
            Spacer(minLength: 4)
            actions()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .help("Close")
            .accessibilityLabel("Close notice")
        }
        .buttonStyle(.plain)
        .font(Token.Type_.monoSmall)
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint)
    }
}

#Preview("Notices", traits: .fixedLayout(width: 420, height: 120)) {
    VStack(spacing: 8) {
        NoticeBar(symbol: "arrow.clockwise.circle.fill",
                  message: "Reloaded — the file changed on disk", dismiss: {})
        NoticeBar(symbol: "exclamationmark.triangle.fill",
                  message: "Changed on disk while you were editing. Nothing was overwritten.",
                  tint: Color.orange.opacity(0.18), dismiss: {}) {
            Button("Reload") {}
        }
        NoticeBar(symbol: "xmark.octagon.fill",
                  message: "Could not save: permission denied", dismiss: {})
    }
    .padding()
}
