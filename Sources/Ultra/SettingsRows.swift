import SwiftUI
import UltraDesign

/// The rows every settings tab is built from, so a slider on one tab and a slider on
/// another cannot come out two different widths.
///
/// Every binding reads `PreferencesModel.revision` so a control notices a reset made from
/// another tab — without it a control shows what it had at first draw and never moves.
@MainActor
struct SettingRows {
    let prefs: PreferencesModel

    /// A slider measured in seconds.
    func seconds(_ title: String,
                 _ get: @escaping () -> CGFloat,
                 _ set: @escaping (CGFloat) -> Void,
                 range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: range, step: 1)
                    .frame(width: 170)
                Text("\(Int(get())) s")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

/// The small print under a control: what it does, and why the default is what it is.
struct SettingNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}
