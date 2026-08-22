import SwiftUI
import UltraDesign

/// The Settings window (⌘,).
struct UltraSettings: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @State private var guardState = SleepGuard.shared
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
            Section("Terminal") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: prefs.number({ Preferences.terminalFontSize },
                                                   { Preferences.terminalFontSize = $0 }),
                               in: 8...32, step: 1)
                            .frame(width: 180)
                        Text("\(Int(Preferences.terminalFontSize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                Picker("Theme", selection: prefs.theme()) {
                    ForEach(Preferences.ThemeMode.allCases) { Text($0.title).tag($0) }
                }

                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: prefs.number({ Preferences.terminalBackgroundOpacity },
                                                   { Preferences.terminalBackgroundOpacity = $0 }),
                               in: 0...1, step: 0.01)
                            .frame(width: 180)
                        Text("\(Int(Preferences.terminalBackgroundOpacity * 100))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                Text("""
                     At 0% a shell has no surface of its own and the pane's glass shows \
                     through the cells. Raising it makes shells opaque — and gives a \
                     shell's header something to blur.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section("Files") {
                Toggle("Show dotfiles in the file tree",
                       isOn: prefs.flag({ Preferences.showsHiddenFiles },
                                        { Preferences.showsHiddenFiles = $0 }))
                Text("The starting state for new file-tree panes. Each pane can still be "
                     + "toggled on its own.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                LabeledContent("Todo file") {
                    TextField("", text: prefs.text({ Preferences.defaultTodoPath },
                                                   { Preferences.defaultTodoPath = $0 }))
                        .frame(width: 200)
                }
                LabeledContent("Context file") {
                    TextField("", text: prefs.text({ Preferences.defaultContextPath },
                                                   { Preferences.defaultContextPath = $0 }))
                        .frame(width: 200)
                }
                Text("Where these live in a project that has not chosen for itself. A "
                     + "project's own choice always wins.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Section("Updating") {
                intervalRow("Ports", { Preferences.portsInterval },
                            { Preferences.portsInterval = $0 }, 1...30)
                intervalRow("Resources", { Preferences.resourcesInterval },
                            { Preferences.resourcesInterval = $0 }, 1...30)
                intervalRow("Git", { Preferences.gitInterval },
                            { Preferences.gitInterval = $0 }, 1...60)
                Toggle("Pause while the window is hidden",
                       isOn: prefs.flag({ Preferences.pausePollingWhenOccluded },
                                        { Preferences.pausePollingWhenOccluded = $0 }))
                Text("Each of these runs a real command — lsof, ps, git. Behind a hidden "
                     + "window that is battery spent updating pixels nobody can see.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Section {
                Toggle("Keep this Mac awake while an agent is running",
                       isOn: Binding(get: { guardState.isEnabled },
                                     set: { guardState.isEnabled = $0 }))
                Text(guardState.statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Agents")
            } footer: {
                // Says what it does AND what it cannot do. A setting that quietly fails to
                // deliver what its title implies is worse than no setting.
                Text("""
                     An agent can run for many minutes with nobody touching the keyboard, \
                     so the Mac reaches its idle timeout, sleeps the display and locks. \
                     While an agent is running, Ultra asks the system to stay awake, and \
                     stops asking the moment it finishes.

                     This does not override locking you trigger yourself, closing the lid, \
                     or a policy set by your organisation.
                     """)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            }

            Section {
                Button("Reset to Defaults") { Preferences.reset() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 560)
    }

    private func intervalRow(_ title: String,
                             _ get: @escaping () -> CGFloat,
                             _ set: @escaping (CGFloat) -> Void,
                             _ range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: prefs.number(get, set), in: range, step: 1)
                    .frame(width: 160)
                Text("\(Int(get())) s")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Token.Colour.accent)
                .padding(.top, 22)

            Text("Ultra")
                .font(.system(size: 22, weight: .bold))

            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("A split-pane terminal for working alongside agent CLIs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            Divider().padding(.horizontal, 40).padding(.vertical, 4)

            Text("Terminal emulation by SwiftTerm.")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}
