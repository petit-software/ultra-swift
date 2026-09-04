import SwiftUI
import UltraCore
import UltraDesign
import UltraTerminal
import UltraTiles

/// The Settings window (⌘,).
///
/// One tab per THING the app has — the terminal, the tiles, the agents, the window, the
/// panes — rather than one General tab holding everything that is not a colour. General
/// held seven sections and Appearance six, and finding "how often does the Git tile
/// refresh" meant reading both to learn which one had been chosen for it. Now the tab
/// names answer that before it is asked.
struct UltraSettings: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Terminal", systemImage: "apple.terminal") { TerminalSettings() }
            Tab("Tiles", systemImage: "square.grid.2x2") { TileSettings() }
            Tab("Agents", systemImage: "sparkles") { AgentSettings() }
            Tab("Appearance", systemImage: "paintbrush") { AppearanceSettings() }
            Tab("Panes", systemImage: "square.split.2x1") { PaneAppearanceSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 520)
    }
}

/// Where the app starts, how it updates, and the one button that puts everything back.
private struct GeneralSettings: View {
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
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
                SettingNote("Left unset, Ultra reopens the project you used most recently — "
                            + "which is right until you stop opening new ones, and then it is "
                            + "the same folder every launch. Naming one here settles it. "
                            + "Launching from a terminal still wins: that is a choice about "
                            + "one launch.")
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
                Toggle("Show Ultra in the menu bar",
                       isOn: prefs.flag({ Preferences.showsMenuBarIcon },
                                        { Preferences.showsMenuBarIcon = $0 }))
            } header: {
                Text("Menu bar")
            } footer: {
                SettingNote("The menu bar is the only place Ultra can say anything while its "
                            + "windows are closed or buried, which is when an agent is usually "
                            + "running. It shows the same count as the Dock icon.")
            }

            Section {
                LabeledContent("Default layout") {
                    HStack(spacing: 6) {
                        Text(hasDefaultLayout ? "Set" : "None")
                            .font(.callout)
                            .foregroundStyle(hasDefaultLayout ? .primary : .secondary)
                        Button("Clear") {
                            layoutStorage.clearDefaultLayout()
                            hasDefaultLayout = layoutStorage.hasDefaultLayout
                        }
                        .disabled(!hasDefaultLayout)
                    }
                }
            } header: {
                Text("Layout")
            } footer: {
                SettingNote("A project opened for the first time takes the default layout. "
                            + "Set one from any project with Pane ▸ Set as Default Layout, "
                            + "or the ellipsis menu in the toolbar; Use Default Layout "
                            + "puts a project back on it. Without one, a new project opens "
                            + "as a single shell.")
            }

            Section {
                Button("Reset All Settings") { Preferences.reset() }
            } footer: {
                SettingNote("Every setting on every tab, back to what Ultra ships with. "
                            + "Layouts are not settings: the default layout above and each "
                            + "project's own arrangement are left alone.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 520)
        .onAppear { hasDefaultLayout = layoutStorage.hasDefaultLayout }
    }

    /// The same store the windows write to. Read on appearance rather than watched: the
    /// file changes from a menu command, and a settings tab is not open at that moment.
    private let layoutStorage = WorkspaceStorage()
    @State private var hasDefaultLayout = false

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
}

/// The shell panes: how they draw and what they are allowed to do.
private struct TerminalSettings: View {
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
            Section("Text") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: prefs.number({ Preferences.terminalFontSize },
                                                   { Preferences.terminalFontSize = $0 }),
                               in: 8...32, step: 1)
                            .frame(width: 170)
                        Text("\(Int(Preferences.terminalFontSize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Audible bell",
                       isOn: prefs.flag({ Preferences.audibleBell },
                                        { Preferences.audibleBell = $0 }))
            } header: {
                Text("Bell")
            } footer: {
                SettingNote("Lets a shell ring the system alert sound. Off by default because "
                            + "agents ring it constantly — on tool calls, on prompts, on "
                            + "finishing — and several agent panes ring it several times over. "
                            + "When it is on, a burst of bells is collapsed into a single ring.")
            }

            Section {
                Toggle("Draw terminals on the GPU",
                       isOn: prefs.flag({ Preferences.useMetalRenderer },
                                        { Preferences.useMetalRenderer = $0 }))
            } header: {
                Text("Rendering")
            } footer: {
                SettingNote("Moves glyph drawing to Metal, which mainly shows up in "
                            + "fast-scrolling output. Off by default because it can fail to "
                            + "start on some hardware — a pane that cannot use it says so and "
                            + "keeps drawing.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 400)
    }
}

/// Every pane that is not a shell: where its files live and how often it looks.
private struct TileSettings: View {
    @State private var prefs = PreferencesModel.shared
    private var rows: SettingRows { SettingRows(prefs: prefs) }

    var body: some View {
        Form {
            Section {
                Toggle("Show dotfiles",
                       isOn: prefs.flag({ Preferences.showsHiddenFiles },
                                        { Preferences.showsHiddenFiles = $0 }))
            } header: {
                Text("File tree")
            } footer: {
                SettingNote("The starting state for new file-tree panes. Each pane can still "
                            + "be toggled on its own.")
            }

            Section {
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
            } header: {
                Text("Project files")
            } footer: {
                SettingNote("Where these live in a project that has not chosen for itself, "
                            + "relative to the project folder. A project's own choice always "
                            + "wins.")
            }

            Section {
                rows.seconds("Ports", { Preferences.portsInterval },
                             { Preferences.portsInterval = $0 }, range: 1...30)
                rows.seconds("Resources", { Preferences.resourcesInterval },
                             { Preferences.resourcesInterval = $0 }, range: 1...30)
                rows.seconds("Git", { Preferences.gitInterval },
                             { Preferences.gitInterval = $0 }, range: 1...60)
                Toggle("Pause while the window is hidden",
                       isOn: prefs.flag({ Preferences.pausePollingWhenOccluded },
                                        { Preferences.pausePollingWhenOccluded = $0 }))
            } header: {
                Text("Refresh every")
            } footer: {
                SettingNote("Each of these runs a real command — lsof, ps, git. Behind a "
                            + "hidden window that is battery spent updating pixels nobody can "
                            + "see.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 480)
    }
}

/// What Ultra does on an agent's behalf while nobody is at the keyboard.
private struct AgentSettings: View {
    @State private var guardState = SleepGuard.shared
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep this Mac awake while an agent is running",
                       isOn: Binding(get: { guardState.isEnabled },
                                     set: { guardState.isEnabled = $0 }))
                Text(guardState.statusDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sleep")
            } footer: {
                // Says what it does AND what it cannot do. A setting that quietly fails to
                // deliver what its title implies is worse than no setting.
                SettingNote("""
                            An agent can run for many minutes with nobody touching the \
                            keyboard, so the Mac reaches its idle timeout, sleeps the display \
                            and locks. While an agent is running, Ultra asks the system to \
                            stay awake, and stops asking the moment it finishes.

                            This does not override locking you trigger yourself, closing the \
                            lid, or a policy set by your organisation.
                            """)
            }

            Section {
                Toggle("Notify me when a long-running agent finishes",
                       isOn: prefs.flag({ Preferences.notifiesOnAgentCompletion },
                                        { Preferences.notifiesOnAgentCompletion = $0 }))
            } header: {
                Text("Notifications")
            } footer: {
                SettingNote("""
                            Only for agents that ran longer than \
                            \(Int(AgentCompletionPolicy.minimumDuration)) seconds, and only \
                            when you are not already looking at Ultra. Turning this on asks \
                            macOS for permission to show notifications.
                            """)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
        .frame(height: 400)
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
