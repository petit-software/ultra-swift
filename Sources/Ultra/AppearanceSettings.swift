import SwiftUI
import UltraDesign

/// The Appearance tab: the app as a whole — its theme, its accent, and the window every
/// pane sits in. What a PANE looks like is the next tab over.
///
/// Every control shows its live value and every default is the value the app shipped with,
/// so "Reset Appearance" is always a way back to a known-good look.
struct AppearanceSettings: View {
    @State private var prefs = PreferencesModel.shared
    private var rows: SettingRows { SettingRows(prefs: prefs) }

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
                SettingNote("""
                            One accent, used everywhere the app tints something — focus \
                            rings, checkboxes, drop targets, selected rows. There is no \
                            second accent to fall out of step.
                            """)
            }

            Section {
                Picker("Backdrop", selection: rows.choice({ Appearance.windowMaterial },
                                                          { Appearance.windowMaterial = $0 })) {
                    ForEach(Appearance.WindowMaterial.allCases) { Text($0.title).tag($0) }
                }
                rows.percent("Tint — dark", { Appearance.windowTintDark },
                             { Appearance.windowTintDark = $0 })
                rows.percent("Tint — light", { Appearance.windowTintLight },
                             { Appearance.windowTintLight = $0 })
                rows.points("Corner radius", { Appearance.windowRadius },
                            { Appearance.windowRadius = $0 },
                            range: Token.Space.systemWindowRadius...44, step: 0.5)
                rows.points("Inner padding", { Appearance.windowPadding },
                            { Appearance.windowPadding = $0 }, range: 0...48)
                rows.points("Border width", { Appearance.windowBorderWidth },
                            { Appearance.windowBorderWidth = $0 }, range: 0...4, step: 0.5)
                rows.percent("Border strength", { Appearance.windowBorderStrength },
                             { Appearance.windowBorderStrength = $0 })
            } header: {
                Text("Window")
            } footer: {
                SettingNote("""
                            The tint is laid ON the backdrop, not mixed into it, so it means \
                            the same thing whatever is behind the window. It darkens in dark \
                            appearance and lightens in light one, which is why the two have \
                            separate amounts.

                            The corner radius cannot go below \
                            \(String(format: "%.1f", Token.Space.systemWindowRadius))pt: macOS \
                            masks the window to that shape and a smaller radius draws a second \
                            arc inside the system's own.

                            Inner padding holds the panes off the window's left, right and \
                            bottom edges. The top is left to the toolbar, which already sets \
                            the panes below it. At zero the panes run to the window's edge \
                            and the backdrop is visible only in the gaps between them.
                            """)
            }

            ResetAppearanceSection()
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 560)
    }
}

/// The Panes tab: the glass a pane is made of, its shape, and the header floating on it.
///
/// Split from Appearance because it was two-thirds of that tab. Someone adjusting the
/// gap between panes is not looking for the window's tint, and twenty sliders in one
/// scroll is a wall rather than a list.
struct PaneAppearanceSettings: View {
    @State private var prefs = PreferencesModel.shared
    private var rows: SettingRows { SettingRows(prefs: prefs) }

    var body: some View {
        Form {
            Section {
                rows.percent("Pane opacity", { Preferences.terminalBackgroundOpacity },
                             { Preferences.terminalBackgroundOpacity = $0 })

                Picker("Glass style", selection: rows.choice({ Appearance.glassStyle },
                                                             { Appearance.glassStyle = $0 })) {
                    ForEach(Appearance.GlassStyle.allCases) { Text($0.title).tag($0) }
                }

                Picker("Glass tint", selection: rows.choice({ Appearance.glassTint },
                                                            { Appearance.glassTint = $0 })) {
                    ForEach(Appearance.GlassTint.allCases) { Text($0.title).tag($0) }
                }

                rows.percent("Tint strength", { Appearance.glassTintStrength },
                             { Appearance.glassTintStrength = $0 }, range: 0...0.6)
                    .disabled(Appearance.glassTint == .off)

                Toggle("Merge nearby panes into one sheet of glass",
                       isOn: prefs.flag({ Appearance.mergesPaneGlass },
                                        { Appearance.mergesPaneGlass = $0 }))

                rows.points("Merge distance", { Appearance.glassMergeSpacing },
                            { Appearance.glassMergeSpacing = $0 }, range: 0...60)
                    .disabled(!Appearance.mergesPaneGlass)
            } header: {
                Text("Glass")
            } footer: {
                SettingNote("""
                            Pane opacity lays the theme's background under every pane alike — \
                            shells, file trees, todo lists. At 0% a pane has no surface of its \
                            own and the glass shows straight through it.

                            Merging batches every pane's glass into one render pass, which is \
                            cheaper to draw. At a merge distance above zero it also fuses \
                            panes that come within that many points of each other into a \
                            single surface, so the gutters between them disappear.
                            """)
            }

            Section {
                rows.points("Corner radius", { Appearance.paneRadius },
                            { Appearance.paneRadius = $0 }, range: 0...36)
                rows.points("Gap between panes", { Appearance.paneGutter },
                            { Appearance.paneGutter = $0 }, range: 0...40)
                rows.points("Shadow size", { Appearance.paneShadowRadius },
                            { Appearance.paneShadowRadius = $0 }, range: 0...36)
                rows.percent("Shadow strength", { Appearance.paneShadowOpacity },
                             { Appearance.paneShadowOpacity = $0 })
                rows.points("Focus ring width", { Appearance.focusRingWidth },
                            { Appearance.focusRingWidth = $0 }, range: 0...6, step: 0.5)
                rows.percent("Focus ring strength", { Appearance.focusRingStrength },
                             { Appearance.focusRingStrength = $0 }, range: 0.05...1)
            } header: {
                Text("Shape")
            } footer: {
                SettingNote("""
                            The gap is what makes the window's material visible at all — at \
                            6pt the glass was there and invisible. The focused pane also \
                            lifts, so focus stays legible for anyone who cannot separate the \
                            accent from grey.
                            """)
            }

            Section {
                rows.points("Blur radius", { Appearance.headerBlurRadius },
                            { Appearance.headerBlurRadius = $0 }, range: 0...40)
                rows.percent("Tint strength", { Appearance.headerTintOpacity },
                             { Appearance.headerTintOpacity = $0 })
            } header: {
                Text("Headers")
            } footer: {
                SettingNote("""
                            A pane's title floats over its content with no background of its \
                            own. Blur separates it from a busy backdrop; over a near-uniform \
                            one the tint is what does the work. At a blur radius of 0 no \
                            filter runs at all.
                            """)
            }

            ResetAppearanceSection()
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 560)
    }
}

/// One reset for the look, on both tabs that hold it. The two tabs are one set of values
/// shown in two halves, and a reset that only reached the half you were on would leave
/// the other half saying the button had not worked.
private struct ResetAppearanceSection: View {
    var body: some View {
        Section {
            Button("Reset Appearance") { Appearance.reset() }
        } footer: {
            SettingNote("Puts every control on the Appearance and Panes tabs back to the "
                        + "value Ultra ships with. Theme and accent are left alone.")
        }
    }
}
