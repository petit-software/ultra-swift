import SwiftUI
import UltraDesign

/// The Appearance tab: everything about how the app LOOKS, in one place.
///
/// Theme, accent and pane opacity moved here from General, which now holds only what the app
/// *does*. The rest were constants in `Token` until they needed to be judged against a real
/// desktop rather than argued about in a diff.
///
/// Every control shows its live value and every default is the value the app shipped with,
/// so "Reset Appearance" is always a way back to a known-good look.
struct AppearanceSettings: View {
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: prefs.theme()) {
                    ForEach(Preferences.ThemeMode.allCases) { Text($0.title).tag($0) }
                }

                Picker("Accent", selection: prefs.accent()) {
                    ForEach(Preferences.AccentColour.allCases) { choice in
                        Label {
                            Text(choice.title)
                        } icon: {
                            Circle().fill(choice.color).frame(width: 12, height: 12)
                        }
                        .tag(choice)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("""
                     One accent, used everywhere the app tints something — focus rings, \
                     checkboxes, drop targets, selected rows. There is no second accent to \
                     fall out of step.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                percentRow("Pane opacity", { Preferences.terminalBackgroundOpacity },
                           { Preferences.terminalBackgroundOpacity = $0 })

                Picker("Glass style", selection: choice({ Appearance.glassStyle },
                                                        { Appearance.glassStyle = $0 })) {
                    ForEach(Appearance.GlassStyle.allCases) { Text($0.title).tag($0) }
                }

                Picker("Glass tint", selection: choice({ Appearance.glassTint },
                                                       { Appearance.glassTint = $0 })) {
                    ForEach(Appearance.GlassTint.allCases) { Text($0.title).tag($0) }
                }

                percentRow("Tint strength", { Appearance.glassTintStrength },
                           { Appearance.glassTintStrength = $0 }, range: 0...0.6)
                    .disabled(Appearance.glassTint == .off)

                Toggle("Merge nearby panes into one sheet of glass",
                       isOn: prefs.flag({ Appearance.mergesPaneGlass },
                                        { Appearance.mergesPaneGlass = $0 }))

                pointRow("Merge distance", { Appearance.glassMergeSpacing },
                         { Appearance.glassMergeSpacing = $0 }, range: 0...60)
                    .disabled(!Appearance.mergesPaneGlass)
            } header: {
                Text("Glass")
            } footer: {
                Text("""
                     Pane opacity lays the theme's background under every pane alike — \
                     shells, file trees, todo lists. At 0% a pane has no surface of its own \
                     and the glass shows straight through it.

                     Merging batches every pane's glass into one render pass, which is \
                     cheaper to draw. At a merge distance above zero it also fuses panes \
                     that come within that many points of each other into a single surface, \
                     so the gutters between them disappear.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                pointRow("Corner radius", { Appearance.paneRadius },
                         { Appearance.paneRadius = $0 }, range: 0...36)
                pointRow("Gap between panes", { Appearance.paneGutter },
                         { Appearance.paneGutter = $0 }, range: 0...40)
                pointRow("Shadow size", { Appearance.paneShadowRadius },
                         { Appearance.paneShadowRadius = $0 }, range: 0...36)
                percentRow("Shadow strength", { Appearance.paneShadowOpacity },
                           { Appearance.paneShadowOpacity = $0 })
                pointRow("Focus ring width", { Appearance.focusRingWidth },
                         { Appearance.focusRingWidth = $0 }, range: 0...6, step: 0.5)
                percentRow("Focus ring strength", { Appearance.focusRingStrength },
                           { Appearance.focusRingStrength = $0 }, range: 0.05...1)
            } header: {
                Text("Panes")
            } footer: {
                Text("""
                     The gap is what makes the window's material visible at all — at 6pt the \
                     glass was there and invisible. The focused pane also lifts, so focus \
                     stays legible for anyone who cannot separate the accent from grey.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                Picker("Backdrop", selection: choice({ Appearance.windowMaterial },
                                                     { Appearance.windowMaterial = $0 })) {
                    ForEach(Appearance.WindowMaterial.allCases) { Text($0.title).tag($0) }
                }
                percentRow("Tint — dark", { Appearance.windowTintDark },
                           { Appearance.windowTintDark = $0 })
                percentRow("Tint — light", { Appearance.windowTintLight },
                           { Appearance.windowTintLight = $0 })
                pointRow("Corner radius", { Appearance.windowRadius },
                         { Appearance.windowRadius = $0 },
                         range: Token.Space.systemWindowRadius...44, step: 0.5)
                pointRow("Inner padding", { Appearance.windowPadding },
                         { Appearance.windowPadding = $0 }, range: 0...48)
                pointRow("Border width", { Appearance.windowBorderWidth },
                         { Appearance.windowBorderWidth = $0 }, range: 0...4, step: 0.5)
                percentRow("Border strength", { Appearance.windowBorderStrength },
                           { Appearance.windowBorderStrength = $0 })
            } header: {
                Text("Window")
            } footer: {
                Text("""
                     The tint is laid ON the backdrop, not mixed into it, so it means the \
                     same thing whatever is behind the window. It darkens in dark appearance \
                     and lightens in light one, which is why the two have separate amounts.

                     The corner radius cannot go below \
                     \(Token.Space.systemWindowRadius, specifier: "%.1f")pt: macOS masks the \
                     window to that shape and a smaller radius draws a second arc inside the \
                     system's own.

                     Inner padding holds the panes off the window's left, right and bottom \
                     edges. The top is left to the toolbar, which already sets the panes \
                     below it — padding there would read as a second gap rather than as \
                     breathing room. At zero the panes run to the window's edge and the \
                     backdrop is visible only in the gaps between them.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                pointRow("Blur radius", { Appearance.headerBlurRadius },
                         { Appearance.headerBlurRadius = $0 }, range: 0...40)
                percentRow("Tint strength", { Appearance.headerTintOpacity },
                           { Appearance.headerTintOpacity = $0 })
            } header: {
                Text("Pane headers")
            } footer: {
                Text("""
                     A pane's title floats over its content with no background of its own. \
                     Blur separates it from a busy backdrop; over a near-uniform one the \
                     tint is what does the work. At a blur radius of 0 no filter runs at all.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset Appearance") { Appearance.reset() }
            } footer: {
                Text("Puts every control on this tab back to the value Ultra ships with. "
                     + "Theme and accent are left alone.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 560)
    }

    // MARK: - Rows

    /// A slider that reads as a percentage. Everything here that is a strength or an opacity
    /// uses it, so "28%" means the same thing in every row.
    private func percentRow(_ title: String,
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
    private func pointRow(_ title: String,
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

    /// A binding for one of the picker-backed settings. Reads `revision` for the same reason
    /// `PreferencesModel`'s own bindings do: without it the control shows what it had at
    /// first draw and never notices a reset.
    private func choice<T>(_ get: @escaping () -> T,
                           _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { _ = prefs.revision; return get() }, set: set)
    }
}
