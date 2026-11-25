import SwiftUI
import UltraCore
import UltraDesign
import UltraTerminal
import UltraTiles

/// The Settings window (⌘,).
///
/// One tab per THING the app has — the terminal, the tiles, the agents — rather than one
/// General tab holding everything that is not a colour. General held seven sections and
/// Appearance six, and finding "how often does the Git tile refresh" meant reading both to
/// learn which one had been chosen for it. Now the tab names answer that before it is asked.
///
/// There is no Appearance tab and no Panes tab. The twenty numbers the look is made of —
/// glass, corners, shadows, the window's tint and edge — were sliders while the look was
/// being found, and once it was found the sliders came out: what they settled on is the
/// default in `Appearance`, and a tab of them only invited undoing it. The accent is the
/// one choice that survived, and it sits with the terminal, which is what it colours. One
/// switch came back since: General ▸ Appearance turns the panes' glass off altogether,
/// which is not a number to tune but a material to decline.
///
/// The theme picker is back, on an Appearance tab, since the light look is being tuned:
/// Dark, Light and Follow System, and under them the three numbers only light appearance
/// draws with (`LightModeSections`). The dark look's numbers stay out, as above.
///
/// The panes are listed DOWN THE SIDE, as System Settings lists its own, not across the
/// top: eight names had outgrown a toolbar's row, the window changed height with every
/// tab, and the main window already navigates from a sidebar. One size of window now, and
/// each pane scrolls inside it.
struct UltraSettings: View {
    @State private var pane = SettingsPane.general
    /// What is typed in the sidebar's search field. While there is something, the sidebar
    /// lists the options it finds in place of the panes (`SettingsSearch`).
    @State private var query = ""

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            Group {
                if isSearching {
                    searchResults
                } else {
                    List(SettingsPane.shown, selection: selection) { pane in
                        Label { Text(pane.title) } icon: { SettingsPaneIcon(pane: pane) }
                            .tag(pane)
                    }
                }
            }
            // At the head of the sidebar, where System Settings has its own. ⌘F goes to
            // it, and the arrow keys go down from it into what it found.
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            // The list is always there: it is the only way round the window.
            .toolbar(removing: .sidebarToggle)
            // Outside `toolbar(removing:)`, which drops a width set inside it.
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .terminal: TerminalSettings()
                case .tiles: TileSettings()
                case .agents: AgentSettings()
                case .chat: ChatSettings()
                case .tuning: TuningSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The window is "Settings" to the Window menu and Mission Control, and that
            // name is not drawn: the sidebar's selected row already says which pane this
            // is, and a bar across the pane's head saying it again was a second header.
            .navigationTitle("Settings")
            .toolbar(removing: .title)
            // Its background only. Hiding the window's toolbar itself takes the traffic
            // lights with it, and a window with no close button is not a window.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // And no band where it stood: the pane starts at the top of the window, the
            // traffic lights being over the sidebar, with no hairline under a titlebar
            // that holds nothing.
            .ignoresSafeArea(.container, edges: .top)
            // The first section's heading level with the traffic lights' row, clear of
            // the window's corner.
            .safeAreaPadding(.top, 10)
            .scrollEdgeEffectHidden(true, for: .top)
            .background { SettingsWindowChrome().accessibilityHidden(true) }
        }
        .frame(width: Self.sidebarWidth + 560, height: 560)
    }

    private static let sidebarWidth: CGFloat = 190

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The options the query finds, each with where it is. Choosing one shows its pane;
    /// the first is shown as soon as it is found, so typing alone gets there.
    @ViewBuilder private var searchResults: some View {
        let results = SettingsSearch.results(for: query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results, selection: resultSelection) { option in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.title).lineLimit(2)
                        Text(option.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    SettingsPaneIcon(pane: option.pane)
                }
                .tag(option.id)
            }
            .onChange(of: results.first, initial: true) { _, first in
                if let first { pane = first.pane }
            }
        }
    }

    /// The result chosen: none is marked until one is clicked or arrowed to, and choosing
    /// one shows its pane.
    @State private var chosenResult: String?
    private var resultSelection: Binding<String?> {
        Binding(get: { chosenResult }, set: { id in
            chosenResult = id
            if let option = SettingsSearch.options.first(where: { $0.id == id }) { pane = option.pane }
        })
    }

    /// A list's selection is optional; a click on the empty space under the rows must
    /// not leave the window showing nothing.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let new = $0 { pane = new } })
    }
}

/// The panes of the Settings window, in the order its sidebar lists them.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, terminal, tiles, agents, chat, tuning, about

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .terminal: "apple.terminal"
        case .tiles: "square.grid.2x2"
        case .agents: "sparkles"
        case .chat: "text.bubble"
        case .tuning: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// The plate its icon sits on in the sidebar: one of the colours a project can wear
    /// (`SessionTint`, the Customize sheet's swatches), a different one for each pane.
    /// Never `.accent` — the accent is white out of the box, and a white glyph on a
    /// white plate is a blank square.
    var tint: SessionTint {
        switch self {
        case .general: .gray
        case .appearance: .blue
        case .terminal: .green
        case .tiles: .orange
        case .agents: .purple
        case .chat: .teal
        case .tuning: .pink
        case .about: .indigo
        }
    }

    /// Tuning is Ultra Dev's only: the look's numbers as sliders, for deciding a new
    /// default.
    @MainActor static var shown: [SettingsPane] {
        allCases.filter { $0 != .tuning || TuningSettings.isAvailable }
    }
}

/// A pane's icon as the sidebar draws it: the glyph in white on a rounded square of the
/// pane's colour, the way System Settings marks its own rows.
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(pane.tint.color.gradient)
            .frame(width: 20, height: 20)
            .overlay {
                // The app's own drawing; the SF Symbol only if it cannot be read.
                if let image = SettingsIcons.image(for: pane) {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Takes the titlebar's separator off the Settings window: the line under a bar that is
/// not drawn. The window has one and each column of the split view has its own — the
/// column's is what draws over a pane that scrolls under the titlebar — so both go. The
/// window is the scene's, so it is reached from a view inside it.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            window?.titlebarSeparatorStyle = .none
            // Nor a material of its own over the pane's head.
            window?.titlebarAppearsTransparent = true
            // The traffic lights stay, over the sidebar's head.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = false
            }
            var view = superview
            while let current = view {
                if let split = (current as? NSSplitView)?.delegate as? NSSplitViewController {
                    for item in split.splitViewItems where item.titlebarSeparatorStyle != .none {
                        item.titlebarSeparatorStyle = .none
                    }
                }
                view = current.superview
            }
        }
    }
}

#Preview("Settings") {
    UltraSettings()
}

/// Dark, light or the system's choice, and the light look's own numbers while it is
/// being tuned — see `LightModeSections`.
private struct AppearanceSettings: View {
    @State private var prefs = PreferencesModel.shared

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: prefs.theme()) {
                    ForEach(Preferences.ThemeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                SettingNote("Follow System changes with the Mac's own appearance.")
            }
            Section {
                Toggle("Aurora", isOn: prefs.flag({ Appearance.aurora }, { Appearance.aurora = $0 }))
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: prefs.number({ Appearance.auroraStrength },
                                                   { Appearance.auroraStrength = $0 }),
                               in: 0...1, step: 0.01)
                            .frame(width: 170)
                        Text("\(Int((Appearance.auroraStrength * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                .disabled(!Appearance.aurora)
            } footer: {
                SettingNote("A glow in the project's colour — the one its sidebar row wears — "
                            + "low across the window, under the panes.")
            }
            LightModeSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
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
                SettingNote("Every setting on every pane, back to what Ultra ships with. "
                            + "Layouts are not settings: the default layout above and each "
                            + "project's own arrangement are left alone.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
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

/// The shell panes: what colours they wear, how they draw, and what they are allowed to do.
private struct TerminalSettings: View {
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
                Text("Accent")
            } footer: {
                SettingNote("""
                            One accent, used everywhere the app tints something — focus \
                            rings, checkboxes, drop targets, selected rows. There is no \
                            second accent to fall out of step.
                            """)
            }

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
                Toggle("Prompt menus for @ and /",
                       isOn: prefs.flag({ Preferences.promptMenus },
                                        { Preferences.promptMenus = $0 }))
            } header: {
                Text("Agent prompts")
            } footer: {
                SettingNote("Typing @ or / as the first character of an agent's prompt opens "
                            + "a picker at the caret: @ for a file from the Context pane or the "
                            + "project, / for one of the agent's commands. Anywhere else the "
                            + "character is typed as usual, and typing it twice types it once.")
            }

            Section {
                Picker("⌘-click on a link", selection: prefs.linkClick()) {
                    ForEach(Preferences.LinkClick.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Links")
            } footer: {
                SettingNote("A ⌘-click on a URL or a file path in a shell or agent pane. "
                            + "In Ultra, a page opens in the browser pane and a file in the "
                            + "editor; outside it, in your default browser and in Finder. "
                            + "Asking shows a menu with both. ⌥⌘-click always skips the menu "
                            + "for the default browser, or the file's own app.")
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
                            + "keeps drawing. Dark terminal themes only: a light one is "
                            + "drawn without it.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
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
                Toggle("Open Markdown as a page",
                       isOn: prefs.flag({ Preferences.opensMarkdownReading },
                                        { Preferences.opensMarkdownReading = $0 }))
            } header: {
                Text("Editor")
            } footer: {
                SettingNote("On, a Markdown file opens drawn — headings, lists, tables and "
                            + "code as such — and the footer's pencil (⌃⌘R) shows the text. "
                            + "Off, it opens as text and the footer's book shows the page. "
                            + "The starting state for each file as it is opened.")
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
                Toggle("Write AGENTS.md into new projects",
                       isOn: prefs.flag({ Preferences.writesAgentInstructions },
                                        { Preferences.writesAgentInstructions = $0 }))
            } header: {
                Text("Agents")
            } footer: {
                SettingNote("A project made with File ▸ New Project gets a short AGENTS.md "
                            + "telling an agent to plan in the todo list and how to treat the "
                            + "other files here, plus a CLAUDE.md that imports it. Opening a "
                            + "folder never writes into it; use File ▸ Session ▸ Write "
                            + "AGENTS.md for those. The agents Pane ▸ New Pane lists are "
                            + "added per project in the session's Customize sheet and kept in "
                            + ".ultra/agents.json.")
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
                Toggle("Notify me when an agent finishes or waits for me",
                       isOn: prefs.flag({ Preferences.notifiesOnAgentCompletion }, { on in
                           Preferences.notifiesOnAgentCompletion = on
                           // The footer says switching this on asks macOS. It must, here:
                           // asking only when the first notification was due meant someone
                           // who switched it on and waited for the prompt never saw one.
                           if on { AgentCompletionNotifier.shared.requestAuthorization() }
                       }))
                Picker("When one waits, show", selection: prefs.agentAttention()) {
                    ForEach(Preferences.AgentAttention.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.flag({ Preferences.notifiesOnAgentCompletion }, { _ in }).wrappedValue)
            } header: {
                Text("Notifications")
            } footer: {
                SettingNote("""
                            When an agent's turn ends — it stops printing and stays quiet, \
                            or rings for you — and when one exits. Only for turns longer \
                            than \(Int(AgentCompletionPolicy.minimumTurn)) seconds, unless the \
                            agent rang, and only when you are not already looking at Ultra. \
                            Clicking the notification goes to the session. Turning this on \
                            asks macOS for permission to show notifications.

                            The window to answer in shows the waiting pane in the top \
                            right corner of the display, over whatever app you are in: \
                            click it or press \(AnswerHotKey.display) and what you type \
                            goes to the agent. One tab for each pane that is waiting. An \
                            agent that exits is still a notification.
                            """)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
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
                .foregroundStyle(Token.Colour.accentInk)
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
