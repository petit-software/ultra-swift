import AppKit
import SwiftUI
import UltraCore
import UltraDesign

/// Starting a project that does not exist yet.
///
/// ONE sheet with two modes rather than two sheets, because everything below the picker is
/// the same question — where does it go and what is it called — and two dialogs would have
/// meant two location rows, two name fields and two sets of validation to keep in step.
///
/// The rules themselves are not here. `NewProject` in UltraCore owns what a folder may be
/// called, what a clone lands in, and how git is run; this is the part you can only find out
/// about by looking at it.
struct NewProjectSheet: View {

    enum Mode: String, CaseIterable, Identifiable {
        case folder, clone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folder: "New Folder"
            case .clone: "Clone Repository"
            }
        }
        /// The button that finishes the job, named for what it will do. "OK" on a dialog
        /// that clones a repository is a button that tells you nothing before you press it.
        var action: String {
            switch self {
            case .folder: "Create"
            case .clone: "Clone"
            }
        }
    }

    /// Called with the folder that now exists, and ONLY when "Add to Sidebar" is on. The
    /// sheet does not open sessions itself — that belongs to the window's `SessionList`, and
    /// a view that reached for it would be a second place that knows how a project becomes a
    /// session.
    let open: (String) -> Void
    @Binding var isPresented: Bool

    @State private var mode: Mode = .folder
    @State private var name = ""
    @State private var repository = ""
    @State private var parent: URL = NewProjectSheet.defaultParent()
    @State private var initializesGit = true
    @State private var problem: String?
    @State private var work: Task<Void, Never>?
    /// The sidebar row's colour and mark, chosen BEFORE the project exists.
    ///
    /// Held here and written on success rather than picked afterwards from the row's own
    /// popover, because the moment a project is created is the moment its identity is being
    /// decided — a user who has just typed a name knows what colour it should be, and
    /// sending them back to right-click the row is asking the same question twice.
    @State private var appearance = SessionAppearance.default
    @State private var isChoosingAppearance = false
    /// Whether the finished project is opened as a session, or only made.
    ///
    /// On by default, because making a project you then have to go and open is the odd case.
    /// It exists because the common case is not the only one: cloning a repository to read,
    /// to build, or to point something else at is a perfectly ordinary reason to want the
    /// folder without a row in the sidebar and a shell running in it.
    @State private var addsToSidebar = true

    private var isWorking: Bool { work != nil }

    /// The name the folder will actually get: what was typed, or — while the field is empty
    /// in clone mode — the one git would pick from the URL.
    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard typed.isEmpty, mode == .clone else { return typed }
        return NewProject.folderName(forRepository: repository)
    }

    /// The two modes, as a pill-tab switch.
    ///
    /// ONE background colour in the whole control: the selected pill wears a neutral grey
    /// wash and the unselected one wears nothing. A filled track behind a filled pill was
    /// two greys arguing about which one meant "selected", and an accent fill on top of that
    /// was a third — and unreadable besides, since this app's accent defaults to white.
    ///
    /// The same idea as `Token.Colour.sidebarSelection`, which exists for exactly this
    /// reason: a neutral wash marks the selection and leaves the LABEL to carry the
    /// contrast, which it can do against any appearance because `labelColor` is dynamic.
    private var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { tab in
                Button {
                    withAnimation(Token.Motion.structuralRespectingPreferences) {
                        mode = tab
                        // The two modes ask different things, so a message about the last
                        // one is a message about a field no longer on screen.
                        problem = nil
                    }
                } label: {
                    Text(tab.title)
                        .font(Token.Type_.body)
                        // The weight and the colour do the work the second background used
                        // to: full-strength label on the selected side, secondary on the
                        // other. Both are system colours, so both contrast in either
                        // appearance and under Increase Contrast.
                        .fontWeight(mode == tab ? .semibold : .regular)
                        .foregroundStyle(mode == tab
                                         ? AnyShapeStyle(Token.Colour.label)
                                         : AnyShapeStyle(Token.Colour.secondaryLabel))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background {
                            if mode == tab {
                                Capsule().fill(Token.Colour.label.opacity(0.12))
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        // Centred rather than filling the width: two capsules stretched across 460pt read
        // as a split bar, not as tabs.
        .frame(maxWidth: .infinity)
        .disabled(isWorking)
    }

    /// The sidebar row's colour and mark, as one control: the icon IS the preview, so a row
    /// of swatches inlined in the form would be a second grid competing with the fields
    /// around it for a choice most people will leave alone.
    ///
    /// Dimmed rather than hidden when "Add to Sidebar" is off — a control that vanishes is
    /// one the user has to discover twice — and there is nothing for it to describe when no
    /// row is going to be drawn.
    private var appearanceButton: some View {
        Button { isChoosingAppearance = true } label: {
            SessionIconPreview(appearance: appearance)
                .frame(width: 24, height: 18)
                .contentShape(.rect)
        }
        // NO bordered capsule under it. The icon is a colour, and a control plate behind a
        // colour swatch is a second surface for the eye to read before it gets to the thing
        // being shown — the sidebar row it previews has no plate either.
        .buttonStyle(.plain)
        .disabled(isWorking || !addsToSidebar)
        .opacity(addsToSidebar ? 1 : 0.45)
        .help("Choose the colour and symbol this project's sidebar row will wear")
        .popover(isPresented: $isChoosingAppearance, arrowEdge: .bottom) {
            SessionAppearancePicker(appearance: $appearance)
                .padding(14)
                .frame(width: SessionAppearancePicker.width)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeTabs

            // THE SAME TWO ROWS FIRST, in both modes. What a project is called and where it
            // goes are the questions both modes ask, so they hold the same positions and
            // nothing moves under the pointer when the tabs are switched — the mode-specific
            // row is added at the bottom rather than inserted into the middle.
            Form {
                // The name and the row's mark on ONE line, because they are the same
                // question asked twice — what is this project called, and what does it look
                // like. Down in the button row the icon sat among the controls that decide
                // whether the project happens at all, which is a different kind of decision.
                LabeledContent("Folder Name") {
                    HStack(spacing: 8) {
                        // The prompt carries git's own answer, so an untouched field is not
                        // empty — it is showing what will happen. Typing replaces it.
                        TextField("", text: $name,
                                  prompt: Text(mode == .clone
                                               ? NewProject.folderName(forRepository: repository)
                                               : "my-project"))
                            .labelsHidden()
                            .onChange(of: name) { _, _ in problem = nil }
                        appearanceButton
                    }
                }

                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text(abbreviated(parent))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(parent.path)
                        Spacer(minLength: 0)
                        // Rounded, like every other button in the sheet — a square one here
                        // was the only corner in the dialog that was not.
                        Button("Choose…", action: chooseParent)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }

                switch mode {
                case .clone:
                    // Below the name it fills in, which is the one cost of keeping the rows
                    // aligned across the modes: paste the URL and the name above updates.
                    // Leave the name alone and it stays the one git would have chosen.
                    TextField("Repository URL", text: $repository,
                              prompt: Text("https://github.com/owner/repo.git"))
                        .onChange(of: repository) { _, _ in problem = nil }
                case .folder:
                    Toggle("Initialize a Git repository", isOn: $initializesGit)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Token.Colour.agentFailed)
                    .font(Token.Type_.body)
                    // A git error is several lines and every one of them matters — this is
                    // the text that says "Repository not found" or "Permission denied".
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // On the OTHER side of the buttons, because it is a different kind of thing:
                // Cancel and Create decide whether the project happens, this decides what it
                // will look like once it has. Sitting beside them it would have read as a
                // third way out of the sheet.
                //
                // The icon is the preview. A row of swatches inlined here would have been a
                // second grid competing with the fields above it for a choice most people
                // will leave alone.
                Toggle("Add to Sidebar", isOn: $addsToSidebar)
                    .toggleStyle(.checkbox)
                    .disabled(isWorking)
                    .help("Open the project as a session when it is made")

                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                // Cancel is always live, and during a clone it is the ONLY live control:
                // a clone of a large repository over a slow link is the longest thing this
                // app does, and a sheet with no way out of it gets force-quit.
                // Fully rounded, to match the pills above them — a sheet with pill tabs and
                // rectangular buttons reads as two dialogs stacked.
                //
                // The STOCK bordered styles, not glass. Same reason as the tabs: a sheet is
                // already a material, `.glass` on top of it had nothing to refract, and the
                // pair came out as grey lozenges with no visible difference between the
                // primary action and the way out. Bordered styles also keep the focus ring,
                // the Full Keyboard Access tab stop, and the default/cancel key equivalents,
                // none of which a hand-rolled control gets back without being written again.
                Button("Cancel", role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                // The ONLY filled control in the sheet, which is what makes it read as the
                // primary one — when everything is tinted, nothing stands out.
                // The label is coloured EXPLICITLY, for the same reason as the pill above:
                // `.borderedProminent` writes its label in white, and this app's accent is
                // white by default, so the stock pairing is a white button with a white word
                // on it.
                Button(action: submit) {
                    Text(mode.action).foregroundStyle(Token.Colour.onAccent)
                }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(Token.Colour.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || effectiveName.isEmpty
                              || (mode == .clone && repository.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { work?.cancel() }
    }

    // MARK: - Doing it

    private func submit() {
        problem = nil
        switch mode {
        case .folder: createFolder()
        case .clone: startClone()
        }
    }

    private func createFolder() {
        do {
            let url = try NewProject.createFolder(named: effectiveName, in: parent,
                                                  initializingGit: initializesGit)
            finish(url)
        } catch {
            problem = message(for: error)
        }
    }

    private func startClone() {
        // Held so `Cancel` and a dismissed sheet can both stop it. `NewProject.clone`
        // terminates git on cancellation rather than letting it finish into a folder the
        // user has been told will not be there.
        work = Task {
            let result = await NewProject.clone(repository: repository,
                                                named: effectiveName,
                                                in: parent)
            work = nil
            switch result {
            case .success(let url): finish(url)
            case .failure(.cancelled): break
            case .failure(let failure): problem = message(for: failure)
            }
        }
    }

    private func finish(_ url: URL) {
        isPresented = false
        guard addsToSidebar else {
            // Made, but not opened. Remembered all the same, so it is one press of the
            // sidebar's folder button away rather than something the user has to go and find
            // again in a file picker.
            RecentProjects.remember(url.path)
            return
        }
        // BEFORE the session opens, so the row is drawn wearing its colour on the frame it
        // first appears in rather than flashing the default and correcting itself —
        // `SessionRow` seeds its own copy from the store the first time it is laid out.
        //
        // Writing the default REMOVES the key, so a user who never opened the picker leaves
        // nothing behind. See `SessionAppearanceStore.set`.
        SessionAppearanceStore.set(appearance, forDirectory: url.path)
        open(url.path)
    }

    private func cancel() {
        work?.cancel()
        work = nil
        isPresented = false
    }

    private func message(for error: any Error) -> String {
        guard let failure = error as? NewProject.Failure else { return error.localizedDescription }
        switch failure {
        case .refused(let problem): return problem.message
        case .notCreated(let detail): return detail
        case .gitMissing: return "Git is not installed on this Mac."
        case .cancelled: return ""
        case .gitFailed(_, let output):
            // Git's own words, which are the only ones worth showing: "Repository not
            // found", "Permission denied (publickey)", "could not read Username". A
            // rewritten summary would lose the one line that says what to fix.
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Git failed." : trimmed
        }
    }

    // MARK: - Where it goes

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.prompt = "Choose"
        panel.message = "Where should the project go?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        parent = url
        problem = nil
    }

    /// The folder a new project most likely belongs beside.
    ///
    /// The Settings default first — it is the only place the user has SAID where projects
    /// live — then the folder holding the most recent project, which is the same answer for
    /// anyone who keeps their checkouts together and has never opened Settings. Home last,
    /// so there is always somewhere.
    static func defaultParent(recents: [String] = RecentProjects.list,
                              preferred: String = Preferences.defaultProjectFolder,
                              home: String = NSHomeDirectory(),
                              fileManager: FileManager = .default) -> URL {
        if !preferred.isEmpty, fileManager.fileExists(atPath: preferred) {
            return URL(fileURLWithPath: preferred, isDirectory: true)
        }
        if let recent = recents.first(where: { fileManager.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: recent, isDirectory: true).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

#Preview("New project", traits: .fixedLayout(width: 500, height: 420)) {
    NewProjectSheet(open: { _ in }, isPresented: .constant(true))
}
