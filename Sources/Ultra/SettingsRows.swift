import SwiftUI
import UltraDesign

/// The rows every settings tab is built from, so a slider on the Terminal tab and a slider
/// on the Panes tab cannot come out two different widths.
///
/// Every binding reads `PreferencesModel.revision` so a control notices a reset made from
/// another tab — without it a control shows what it had at first draw and never moves.
@MainActor
struct SettingRows {
    let prefs: PreferencesModel

    /// A slider that reads as a percentage. Everything that is a strength or an opacity
    /// uses it, so "28%" means the same thing in every row.
    func percent(_ title: String,
                 _ get: @escaping () -> CGFloat,
                 _ set: @escaping (CGFloat) -> Void,
                 range: ClosedRange<CGFloat> = 0...1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: range, step: 0.01)
                    .frame(width: 170)
                Text("\(Int((get() * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    /// A slider measured in points. Half-point steps where the shipped value is a half —
    /// a control that cannot reach the default is a control that hides it.
    func points(_ title: String,
                _ get: @escaping () -> CGFloat,
                _ set: @escaping (CGFloat) -> Void,
                range: ClosedRange<CGFloat>,
                step: CGFloat = 1) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: range, step: step)
                    .frame(width: 170)
                Text(step < 1 ? String(format: "%.1f pt", get()) : "\(Int(get())) pt")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

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

    /// A binding for one of the picker-backed settings.
    func choice<T>(_ get: @escaping () -> T,
                   _ set: @escaping @Sendable (T) -> Void) -> Binding<T> {
        Binding(get: { _ = prefs.revision; return get() }, set: set)
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
