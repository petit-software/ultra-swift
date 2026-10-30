import AppKit
import SwiftUI
import UltraDesign

/// The look's numbers as live controls, in Ultra Dev only.
///
/// The sliders were taken out of Settings once the look was decided (see `Appearance`), and
/// that still holds for the app people use. But deciding a new default — the frosted pane,
/// glass off — wants them back, against a real desktop, and then the values carried into
/// the code. Copy Values puts every one on the clipboard in the shape the defaults are
/// written in, so the result can be handed over rather than read off a screen.
struct TuningSettings: View {
    @State private var prefs = PreferencesModel.shared
    @State private var copied = false

    /// The build `scripts/build-app.sh --dev` makes, or one run from SwiftPM with no bundle.
    static var isAvailable: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        return id.hasSuffix(".dev")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Glass panes", isOn: prefs.flag({ Appearance.paneGlass },
                                                       { Appearance.paneGlass = $0 }))
                Picker("Material", selection: choice({ Appearance.frostMaterial },
                                                     { Appearance.frostMaterial = $0 })) {
                    ForEach(Appearance.FrostMaterial.allCases) { Text($0.title).tag($0) }
                }
                Picker("Blurs", selection: choice({ Appearance.frostSource },
                                                  { Appearance.frostSource = $0 })) {
                    ForEach(Appearance.FrostSource.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Blur while in the background",
                       isOn: prefs.flag({ Appearance.frostAlwaysActive },
                                        { Appearance.frostAlwaysActive = $0 }))
                slider("Focused wash", { Appearance.frostFocusedTintDark },
                       { Appearance.frostFocusedTintDark = $0 }, 0...1, percent: true)
                slider("Unfocused wash", { Appearance.frostUnfocusedTintDark },
                       { Appearance.frostUnfocusedTintDark = $0 }, 0...1, percent: true)
                slider("Focused wash, light", { Appearance.frostFocusedTintLight },
                       { Appearance.frostFocusedTintLight = $0 }, 0...1, percent: true)
                slider("Unfocused wash, light", { Appearance.frostUnfocusedTintLight },
                       { Appearance.frostUnfocusedTintLight = $0 }, 0...1, percent: true)
            } header: {
                Text("Frosted panes (glass off)")
            } footer: {
                SettingNote("Turn Glass panes off to see these. A wash is laid over the blur: "
                            + "black in dark appearance, white in light.")
            }

            Section("Glass panes (glass on)") {
                Picker("Style", selection: choice({ Appearance.glassStyle },
                                                  { Appearance.glassStyle = $0 })) {
                    ForEach(Appearance.GlassStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Tint", selection: choice({ Appearance.glassTint },
                                                 { Appearance.glassTint = $0 })) {
                    ForEach(Appearance.GlassTint.allCases) { Text($0.title).tag($0) }
                }
                slider("Tint strength", { Appearance.glassTintStrength },
                       { Appearance.glassTintStrength = $0 }, 0...0.6, percent: true)
            }

            Section("Pane shape") {
                slider("Corner radius", { Appearance.paneRadius },
                       { Appearance.paneRadius = $0 }, 0...36)
                slider("Gutter", { Appearance.paneGutter }, { Appearance.paneGutter = $0 }, 0...40)
                slider("Window padding", { Appearance.windowPadding },
                       { Appearance.windowPadding = $0 }, 0...48)
                slider("Shadow radius", { Appearance.paneShadowRadius },
                       { Appearance.paneShadowRadius = $0 }, 0...36)
                slider("Shadow opacity", { Appearance.paneShadowOpacity },
                       { Appearance.paneShadowOpacity = $0 }, 0...1, percent: true)
                slider("Focus ring width", { Appearance.focusRingWidth },
                       { Appearance.focusRingWidth = $0 }, 0...6, step: 0.5)
                slider("Focus ring strength", { Appearance.focusRingStrength },
                       { Appearance.focusRingStrength = $0 }, 0.05...1, percent: true)
            }

            Section("Pane header") {
                slider("Blur radius", { Appearance.headerBlurRadius },
                       { Appearance.headerBlurRadius = $0 }, 0...40)
                slider("Tint", { Appearance.headerTintOpacity },
                       { Appearance.headerTintOpacity = $0 }, 0...1, percent: true)
            }

            Section("Window") {
                Picker("Material", selection: choice({ Appearance.windowMaterial },
                                                     { Appearance.windowMaterial = $0 })) {
                    ForEach(Appearance.WindowMaterial.allCases) { Text($0.title).tag($0) }
                }
                slider("Dark tint", { Appearance.windowTintDark },
                       { Appearance.windowTintDark = $0 }, 0...1, percent: true)
                slider("Light tint", { Appearance.windowTintLight },
                       { Appearance.windowTintLight = $0 }, 0...1, percent: true)
            }

            Section {
                HStack {
                    Button(copied ? "Copied" : "Copy Values") { copy() }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    Spacer()
                    Button("Reset Look") { Appearance.reset() }
                }
            } footer: {
                SettingNote("Copy Values (⇧⌘C) puts every number on this tab on the clipboard; "
                            + "paste it into the chat to make it the default.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 520)
    }

    private func slider(_ title: String, _ get: @escaping () -> CGFloat,
                        _ set: @escaping (CGFloat) -> Void, _ range: ClosedRange<CGFloat>,
                        step: CGFloat = 1, percent: Bool = false) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: range,
                       step: percent ? 0.01 : step)
                    .frame(width: 170)
                Text(percent ? "\(Int((get() * 100).rounded()))%" : Self.format(get()))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    private func choice<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { _ = prefs.revision; return get() }, set: set)
    }

    private static func format(_ value: CGFloat) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", Double(value))
    }

    /// Every value, by its `Appearance` name, one per line.
    static var values: String {
        let numbers: [(String, CGFloat)] = [
            ("frostFocusedTintDark", Appearance.frostFocusedTintDark),
            ("frostUnfocusedTintDark", Appearance.frostUnfocusedTintDark),
            ("frostFocusedTintLight", Appearance.frostFocusedTintLight),
            ("frostUnfocusedTintLight", Appearance.frostUnfocusedTintLight),
            ("glassTintStrength", Appearance.glassTintStrength),
            ("paneRadius", Appearance.paneRadius),
            ("paneGutter", Appearance.paneGutter),
            ("windowPadding", Appearance.windowPadding),
            ("paneShadowRadius", Appearance.paneShadowRadius),
            ("paneShadowOpacity", Appearance.paneShadowOpacity),
            ("focusRingWidth", Appearance.focusRingWidth),
            ("focusRingStrength", Appearance.focusRingStrength),
            ("headerBlurRadius", Appearance.headerBlurRadius),
            ("headerTintOpacity", Appearance.headerTintOpacity),
            ("windowTintDark", Appearance.windowTintDark),
            ("windowTintLight", Appearance.windowTintLight),
        ]
        let lines = [
            "paneGlass: \(Appearance.paneGlass)",
            "frostMaterial: .\(Appearance.frostMaterial.rawValue)",
            "frostSource: .\(Appearance.frostSource.rawValue)",
            "frostAlwaysActive: \(Appearance.frostAlwaysActive)",
            "glassStyle: .\(Appearance.glassStyle.rawValue)",
            "glassTint: .\(Appearance.glassTint.rawValue)",
            "windowMaterial: .\(Appearance.windowMaterial.rawValue)",
        ] + numbers.map { "\($0.0): \(String(format: "%.2f", Double($0.1)))" }
        return "Ultra look\n" + lines.joined(separator: "\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.values, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

#Preview {
    TuningSettings()
}

/// The light look's numbers, for everyone: Settings ▸ Appearance ▸ Light mode.
///
/// The dark look was tuned against a real desktop with the Tuning tab and then the sliders
/// came out of the app people use. The light look is being tuned now, and the three values
/// that only light appearance draws with — the white washed over the focused pane, over
/// the rest, and over the window's frame — are offered here so the tuning can happen in
/// the app itself. Copy Values puts them on the clipboard in the shape `Appearance` writes
/// its defaults in, so a look that works can be handed over as the next default.
struct LightModeSections: View {
    @State private var prefs = PreferencesModel.shared
    @State private var copied = false

    var body: some View {
        Section {
            slider("Focused pane", { Appearance.frostFocusedTintLight },
                   { Appearance.frostFocusedTintLight = $0 })
            slider("Other panes", { Appearance.frostUnfocusedTintLight },
                   { Appearance.frostUnfocusedTintLight = $0 })
            slider("Window frame", { Appearance.windowTintLight },
                   { Appearance.windowTintLight = $0 })
        } header: {
            Text("Light mode")
        } footer: {
            SettingNote("How much white is laid over each surface. More is whiter paper; less "
                        + "lets the frost's grey through. Seen with Appearance set to Light.")
        }

        Section {
            HStack {
                Button(copied ? "Copied" : "Copy Values") { copy() }
                Spacer()
                Button("Reset Light Mode") { Appearance.reset(Appearance.lightKeys) }
            }
        } footer: {
            SettingNote("Copy Values puts the three numbers on the clipboard; paste them into "
                        + "the chat to make them the default.")
        }
    }

    private func slider(_ title: String, _ get: @escaping () -> CGFloat,
                        _ set: @escaping (CGFloat) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: 0...1, step: 0.01)
                    .frame(width: 170)
                Text("\(Int((get() * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    static var values: String {
        let numbers: [(String, CGFloat)] = [
            ("frostFocusedTintLight", Appearance.frostFocusedTintLight),
            ("frostUnfocusedTintLight", Appearance.frostUnfocusedTintLight),
            ("windowTintLight", Appearance.windowTintLight),
        ]
        return "Ultra light look\n" + numbers.map { "\($0.0): \(String(format: "%.2f", Double($0.1)))" }
            .joined(separator: "\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.values, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
