import SwiftUI
import UltraDesign
import UltraTerminal
import UltraTiles

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
            Section {
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
                Text("Colour")
            } footer: {
                Text("One colour, used everywhere the app tints something — focus rings, "
                     + "checkboxes, drop targets, selected rows. Changing it changes all of "
                     + "them; there is no second accent to fall out of step.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

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

                Toggle("Audible bell",
                       isOn: prefs.flag({ Preferences.audibleBell },
                                        { Preferences.audibleBell = $0 }))
                Text("Lets a shell ring the system alert sound. Off by default because "
                     + "agents ring it constantly — on tool calls, on prompts, on finishing "
                     + "— and several agent panes ring it several times over.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                Toggle("Draw terminals on the GPU",
                       isOn: prefs.flag({ Preferences.useMetalRenderer },
                                        { Preferences.useMetalRenderer = $0 }))
                Text("Moves glyph drawing to Metal, which mainly shows up in fast-scrolling "
                     + "output. Off by default because it can fail to start on some "
                     + "hardware — a pane that cannot use it says so and keeps drawing.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            Section {
                LabeledContent("New windows open in") {
                    HStack(spacing: 6) {
                        Text(startFolderLabel)
                            .font(.callout)
                            .foregroundStyle(Preferences.defaultProjectFolder.isEmpty
                                             ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 200, alignment: .trailing)
                        Button("Choose…") { chooseStartFolder() }
                        Button("Reset") { Preferences.defaultProjectFolder = "" }
                            .disabled(Preferences.defaultProjectFolder.isEmpty)
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Left unset, Ultra reopens the project you used most recently — which "
                     + "is right until you stop opening new ones, and then it is the same "
                     + "folder every launch. Naming one here settles it. Launching from a "
                     + "terminal still wins: that is a choice about one launch.")
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
                if Updater.shared.canCheck {
                    Toggle("Check for updates automatically",
                           isOn: Binding(get: { Updater.shared.checksAutomatically },
                                         set: { Updater.shared.checksAutomatically = $0 }))
                    Button("Check Now…") { Updater.shared.checkForUpdates() }
                } else {
                    // Says WHY rather than hiding an empty section. A missing control with no
                    // explanation is what makes people think the feature is broken.
                    Text(Updater.unavailableReason ?? "Updates are unavailable for this copy.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Keep this Mac awake while an agent is running",
                       isOn: Binding(get: { guardState.isEnabled },
                                     set: { guardState.isEnabled = $0 }))
                Text(guardState.statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Show Ultra in the menu bar",
                       isOn: Binding(get: { Preferences.showsMenuBarIcon },
                                     set: { Preferences.showsMenuBarIcon = $0 }))
                Text("""
                     The menu bar is the only place Ultra can say anything while its \
                     windows are closed or buried, which is when an agent is usually \
                     running. It shows the same count as the Dock icon.
                     """)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Notify me when a long-running agent finishes",
                       isOn: Binding(get: { Preferences.notifiesOnAgentCompletion },
                                     set: { Preferences.notifiesOnAgentCompletion = $0 }))
                Text("""
                     Only for agents that ran longer than \
                     \(Int(AgentCompletionPolicy.minimumDuration)) seconds, and only when \
                     you are not already looking at Ultra. Turning this on asks macOS for \
                     permission to show notifications.
                     """)
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

    /// The stored folder, or what the app will actually do without one — never a blank
    /// field, which reads as broken rather than as unset.
    private var startFolderLabel: String {
        _ = prefs.revision
        let stored = Preferences.defaultProjectFolder
        return stored.isEmpty ? "Most recent project" : ShellPaneFactory.abbreviate(stored)
    }

    private func chooseStartFolder() {
        let current = Preferences.defaultProjectFolder
        let start = URL(fileURLWithPath: current.isEmpty ? NSHomeDirectory() : current)
        guard let url = chooseTileFolder(title: "Folder for New Windows", directory: start)
        else { return }
        Preferences.defaultProjectFolder = url.path
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
    /// Read from the bundle, with no fallback VERSION.
    ///
    /// It used to fall back to a literal "0.1", which is a second place a version number
    /// lives and therefore a place it drifts — About would confidently report a number the
    /// app had not been for months. There is no correct guess here: a bundle with no version
    /// is broken, and saying so is more use to whoever is reading About than a plausible lie.
    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            return "Version unknown"
        }
        let build = info?["CFBundleVersion"] as? String ?? "?"
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
