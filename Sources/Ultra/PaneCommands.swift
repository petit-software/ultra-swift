import SwiftUI
import UltraDesign
import UltraCanvas
import UltraCore
import UltraLayout
import UltraSimulator
import UltraTiles

/// Every pane verb, declared once.
///
/// These are declared on the MAIN MENU rather than on a view, and that is load-bearing:
/// `NSApp.mainMenu.performKeyEquivalent` runs before the key window's first responder sees
/// the event, so these fire even while a full-screen TUI owns the keyboard. A
/// `.keyboardShortcut` on a view inside a pane would never see the key.
enum PaneCommands {

    static let all: [AppCommand] = splits + focusMoves + swaps + resizes + numbered + others
                                 + layouts + chat + editor + browser
                                 + (TileFactory.offersSimulator ? simulator : []) + todo + context + paneKinds + folders
                                 + [newProject, openProject, newShell, openSetup, closeSession, whatsNew]
                                 + [nextSession, previousSession] + prompt
                                 + [showAgents, openAgentProject, openWaiting]
                                 + (AgentsOverview.isDevBuild ? [agentsDemo, projectsDemo] : [])

    /// Ultra Dev only: the overview with three stand-in agents, to look at the design
    /// without running three agents. Not in a release build at all — absent, not dimmed,
    /// since it is for the people building the app and no one else.
    static let agentsDemo = AppCommand(
        id: "debug.agentsDemo", title: "Demo: Agents Overview", symbol: "circle.grid.2x2",
        menuPath: ["View"],
        keywords: ["Debug"],
        isEnabled: { SessionList.holding($0) != nil || AgentsOverview.shared.list != nil }) { store in
            guard let list = SessionList.holding(store) ?? AgentsOverview.shared.list else { return }
            AgentsOverview.shared.showDemo(in: list)
        }

    /// Ultra Dev only: eight generated projects, each a real folder with its own pane
    /// composition, for looking at the app full rather than at one project
    /// (`DemoProjects`). Like `agentsDemo`, absent from a release build.
    static let projectsDemo = AppCommand(
        id: "debug.projectsDemo", title: "Demo: Eight Projects", symbol: "square.grid.3x3.fill",
        menuPath: ["View"],
        keywords: ["Debug", "Demo Projects", "Sample Projects"],
        isEnabled: { SessionList.holding($0) != nil }) { store in
            guard let list = SessionList.holding(store) else { return }
            DemoProjects.show(in: list)
        }

    /// The Agents overview: every working agent's pane, from every project, on one
    /// canvas (`AgentsOverview`). A toggle, so the key that opens it closes it.
    ///
    /// ⌘0: the entry before the first session, as ⌘1…9 are the panes and ⌥⌘[ from the
    /// first session lands on it. ⌃⌘0 is the simulator's Fit Device; nothing with ⌘
    /// reaches a shell.
    static let showAgents = AppCommand(
        id: "view.agents", title: "Show Agents", symbol: "circle.grid.2x2.fill",
        menuPath: ["View"],
        binding: KeyBinding("0", [.command]),
        keywords: ["Agents Overview", "All Agents", "Hide Agents"],
        isEnabled: { SessionList.holding($0) != nil || AgentsOverview.shared.list != nil }) { store in
            guard let list = SessionList.holding(store) ?? AgentsOverview.shared.list else { return }
            AgentsOverview.shared.toggle(in: list)
        }

    /// The pane that has waited longest for an answer, wherever it is: on the overview
    /// when that is up, else in its session, raised. The keyboard answer to the orange
    /// dot without opening the grid. ⌥⌘0, beside ⌘0; dims when nothing is asking.
    static let openWaiting = AppCommand(
        id: "agents.openWaiting", title: "Open Waiting Agent", symbol: "circle.inset.filled",
        menuPath: ["View"],
        binding: KeyBinding("0", [.command, .option]),
        keywords: ["Needs You", "Answer Agent", "Waiting Agent"],
        isEnabled: { _ in !AgentsOverview.shared.waiting.isEmpty }) { _ in
            AgentsOverview.shared.openWaiting()
        }

    /// From the overview, the focused pane's project: the pane goes home and its session
    /// comes on screen with the keyboard in that pane. The strip's arrow is this.
    ///
    /// ⌘↩, beside ⇧⌘↩ for zoom: Return is "go into it". Dims off the overview.
    static let openAgentProject = AppCommand(
        id: "agents.openProject", title: "Open Agent's Project", symbol: "arrow.up.forward.app",
        menuPath: ["View"],
        binding: KeyBinding(.return, [.command]),
        keywords: ["Go to Project", "Go to Agent"],
        isEnabled: { AgentsOverview.shared.canOpenProject(from: $0) }) { store in
            AgentsOverview.shared.openProject(store.tree.focused)
        }

    /// The running version's release list, on request (`WhatsNewChecker`). The only way
    /// to it: Sparkle's update prompt shows the same list before installing, so the app
    /// does not open it again on launch.
    static let whatsNew = AppCommand(
        id: "app.whatsNew", title: "What's New in Ultra…", symbol: "sparkles",
        menuPath: ["Ultra"],
        keywords: ["Release Notes", "Changelog"],
        isEnabled: { SessionList.holding($0)?.ui != nil }) { store in
            guard let ui = SessionList.holding(store)?.ui else { return }
            Task { await WhatsNewChecker.shared.show { ui.whatsNew = $0 } }
        }

    /// A project that does not exist yet: the New Project sheet (`NewProjectSheet`). The
    /// sidebar's `+` and File ▸ New Project… are this. In the registry so the palette finds
    /// it by "project" — it was a menu item only, and the palette, which is where someone
    /// who has forgotten ⇧⌘N looks, had no row for it.
    static let newProject = AppCommand(
        id: "project.new", title: "New Project…", symbol: "folder.badge.plus",
        menuPath: ["File"],
        binding: KeyBinding("n", [.command, .shift]),
        keywords: ["Create Project", "Add Project", "New Folder"],
        isEnabled: { SessionList.holding($0)?.ui != nil }) { store in
            SessionList.holding(store)?.ui?.isCreatingProject = true
        }

    /// A project that is already a folder: the open panel, and a session on each folder
    /// chosen — or the session already on it, selected. File ▸ Open Folder… and ⌘T's New
    /// Session… are both this (`WorkspaceCommands.chooseFolder`); here under the name the
    /// sidebar uses, since a session IS a project, with the menu's words as keywords.
    static let openProject = AppCommand(
        id: "project.open", title: "Open Project…", symbol: "folder",
        menuPath: ["File"],
        binding: KeyBinding("o", [.command, .shift]),
        keywords: ["Open Folder", "New Session", "Add Project", "Open Existing Project"],
        isEnabled: { SessionList.holding($0) != nil }) { store in
            guard let list = SessionList.holding(store) else { return }
            for folder in chooseProjectFolders() { list.open(directory: folder) }
        }

    /// Which session is on screen, from the keyboard: the next one down the sidebar, or
    /// up, wrapping through the Agents overview (`SessionList.step`). View ▸ Next Session
    /// draws from these. In the registry so the palette answers "next project" and
    /// "switch project", which it did not: moving between open projects was the one thing
    /// the sidebar could do that the palette could not name.
    static let nextSession = AppCommand(
        id: "session.next", title: "Next Session", symbol: "arrow.down.to.line",
        menuPath: ["View"],
        binding: KeyBinding("]", [.command, .option]),
        keywords: ["Next Project", "Switch Project", "Switch Session"],
        isEnabled: { SessionList.holding($0) != nil }) { store in
            SessionList.holding(store)?.selectNext()
        }

    static let previousSession = AppCommand(
        id: "session.previous", title: "Previous Session", symbol: "arrow.up.to.line",
        menuPath: ["View"],
        binding: KeyBinding("[", [.command, .option]),
        keywords: ["Previous Project", "Switch Project", "Switch Session"],
        isEnabled: { SessionList.holding($0) != nil }) { store in
            SessionList.holding(store)?.selectPrevious()
        }

    /// One command per open session: "Go to <project>", so a project is reached by typing
    /// its name into the palette rather than stepping past the ones between. Built when
    /// asked — the list changes as projects open and close, and a static registry cannot
    /// hold it — and listed under View ▸ Go to Session, so the menu teaches the same names.
    /// The session on screen is dimmed rather than dropped: a row that vanishes is one the
    /// eye goes looking for.
    @MainActor static func sessionJumps(in store: LayoutStore) -> [AppCommand] {
        guard let list = SessionList.holding(store) else { return [] }
        return list.sessions.map { session in
            let id = session.workspaceID
            return AppCommand(
                id: "session.goto.\(id.uuidString)",
                title: "Go to \(list.title(of: session))",
                symbol: SessionSymbols.resolved(SessionLook.appearance(for: session).symbol),
                menuPath: ["View", "Go to Session"],
                keywords: ["Switch to \(list.title(of: session))", "Open \(list.title(of: session))", "Project"],
                isEnabled: { store in
                    SessionList.holding(store).map { $0.selectedID != id || $0.ui?.showsAgents == true } ?? false
                }) { store in
                    SessionList.holding(store)?.select(id)
                }
        }
    }

    /// The pickers `@` and `/` open at an agent's prompt (`PromptMenu`), from the menu:
    /// the key path when the preference is off, or the prompt is mid-line, or the pane is
    /// a plain shell. They land in the shell a tile's send would — the focused one, else
    /// the last used — and focus it. No chord: the trigger itself is the key.
    static let prompt: [AppCommand] = [
        AppCommand(id: "prompt.files", title: "Insert File Reference…", symbol: "at",
                   menuPath: ["Pane"],
                   keywords: ["Mention File", "@ File", "Attach File", "Pick File"],
                   isEnabled: { ShellWorkspace.Registry.injectionTarget(in: $0.workspaceID) != nil }) { store in
            guard let target = ShellWorkspace.Registry.injectionTarget(in: store.workspaceID) else { return }
            store.focus(target)
            PromptMenu.present("@", pane: target, workspace: store.workspaceID)
        },
        AppCommand(id: "prompt.commands", title: "Insert Agent Command…", symbol: "slash.circle",
                   menuPath: ["Pane"],
                   keywords: ["Slash Command", "/ Command", "Agent Commands"],
                   isEnabled: { store in
                       guard let target = ShellWorkspace.Registry.injectionTarget(in: store.workspaceID) else { return false }
                       return ShellWorkspace.Registry.factories[store.workspaceID]?.shells[target]?.isRunningAgent ?? false
                   }) { store in
            guard let target = ShellWorkspace.Registry.injectionTarget(in: store.workspaceID) else { return }
            store.focus(target)
            PromptMenu.present("/", pane: target, workspace: store.workspaceID)
        },
    ]

    /// A session on no project — one shell, in the home folder, called "New shell". The
    /// belt's `+` after its last tab is this; so is File ▸ New Shell Session, drawn from
    /// here so the two cannot come to say different things.
    ///
    /// ⇧⌘T: ⌘T opens a session on a folder, and ⇧ is "the same, without the question" —
    /// there is no folder to ask for. ⌥⌘T is a shell PANE and ⌃⌘T a browser tab. Not in
    /// the reserved terminal table: ⇧⌘ never reaches a shell.
    static let newShell = AppCommand(
        id: "session.newShell", title: "New Shell Session", symbol: "plus",
        menuPath: ["File"],
        binding: KeyBinding("t", [.command, .shift]),
        keywords: ["New Shell", "Open Shell", "Scratch Shell", "Add Shell"],
        isEnabled: { SessionList.holding($0) != nil }) { store in
            SessionList.holding(store)?.openShell()
        }

    /// Open the project a scratch session's shell has walked into — the keyboard answer to
    /// the toast that asks (`ProjectSetupOffers`). Dimmed when nothing is being offered.
    /// No chord: it answers a question on screen, and the palette is one ⌘K away.
    static let openSetup = AppCommand(
        id: "session.openSetup", title: "Open Ultra Setup", symbol: "folder",
        menuPath: ["File"],
        keywords: ["Open Project Here", "Open This Folder"],
        isEnabled: { ProjectSetupOffers.shared.offer(for: $0) != nil }) { store in
            ProjectSetupOffers.shared.accept(in: store)
        }

    /// Close the session on screen — the project, its shells and its agents.
    ///
    /// In the registry so the palette has it; File ▸ Session draws its item from this
    /// too, so the two cannot come to say different things. It asks first, through the
    /// one question every way of closing a session asks (`UIState.closingSessionID`).
    /// Found by "close project" as well: a session is a project, and that is the word
    /// people reach for.
    ///
    /// ⇧⌃⌘W, beside ⌘W for a pane and ⇧⌘W for the window.
    static let closeSession = AppCommand(
        id: "session.close", title: "Close Session…", symbol: "xmark.rectangle",
        menuPath: ["File", "Session"],
        binding: KeyBinding("w", [.command, .control, .shift]),
        keywords: ["Close Project"],
        isEnabled: { SessionList.holding($0)?.canCloseSelected ?? false }) { store in
            SessionList.holding(store)?.askToClose(store.workspaceID)
        }

    /// A chat pane's verbs that a keystroke should reach: another thread, stop, and its
    /// look. All act on the focused pane and dim when it is not a chat.
    ///
    /// ⌥⌘N sits beside ⌘N (window) and ⇧⌘N (project) as the third kind of new. ⌘. is
    /// the platform's cancel, and it has been free here because a shell's cancel is ⌃C.
    static let chat: [AppCommand] = [
        AppCommand(id: "chat.new", title: "New Chat", symbol: "plus.bubble", menuPath: ["Pane", "Chat"],
                   binding: KeyBinding("n", [.command, .option]),
                   isEnabled: { ShellWorkspace.chatStore(in: $0) != nil }) { store in
            ShellWorkspace.chatStore(in: store)?.newConversation()
        },
        AppCommand(id: "chat.stop", title: "Stop Response", symbol: "stop.circle", menuPath: ["Pane", "Chat"],
                   binding: KeyBinding(".", [.command]),
                   isEnabled: { ShellWorkspace.chatStore(in: $0)?.isStreaming ?? false }) { store in
            ShellWorkspace.chatStore(in: store)?.stop()
        },
        // The keyboard half of the copy icon under every answer. ⇧⌥⌘C beside ⌥⌘C, which
        // makes a chat pane; a terminal sees neither.
        AppCommand(id: "chat.copyLastAnswer", title: "Copy Last Answer", symbol: "square.filled.on.square",
                   menuPath: ["Pane", "Chat"],
                   binding: KeyBinding("c", [.command, .option, .shift]),
                   keywords: ["Copy Answer", "Copy Response"],
                   isEnabled: { ShellWorkspace.chatStore(in: $0)?.lastAnswerText != nil }) { store in
            ShellWorkspace.chatStore(in: store)?.copyLastAnswer()
        },
        // Along the pane's row of chats, and off it. No keys: ⇧⌘] and ⌃⌘] are the
        // editor's and the browser's rows, and the browser's are live whenever a browser
        // pane exists, so a third pair on the same keys would fire two at once. The
        // palette has them, which is the keyboard path a tab strip must have.
        AppCommand(id: "chat.next", title: "Next Chat", symbol: "chevron.right",
                   menuPath: ["Pane", "Chat"],
                   isEnabled: { (ShellWorkspace.chatStore(in: $0)?.openIDs.count ?? 0) > 1 }) { store in
            ShellWorkspace.chatStore(in: store)?.selectNext()
        },
        AppCommand(id: "chat.previous", title: "Previous Chat", symbol: "chevron.left",
                   menuPath: ["Pane", "Chat"],
                   isEnabled: { (ShellWorkspace.chatStore(in: $0)?.openIDs.count ?? 0) > 1 }) { store in
            ShellWorkspace.chatStore(in: store)?.selectPrevious()
        },
        AppCommand(id: "chat.closeTab", title: "Close Chat Tab", symbol: "xmark",
                   menuPath: ["Pane", "Chat"],
                   keywords: ["Close Chat"],
                   isEnabled: { ShellWorkspace.chatStore(in: $0) != nil }) { store in
            guard let chat = ShellWorkspace.chatStore(in: store) else { return }
            chat.close(chat.current.id)
        },
        // ⌃⌘L, the browser's key for the same thing. The two share it on purpose: one key
        // for "this pane, light or not", and the menu fires whichever is enabled — this one
        // only with a chat focused, the browser's whenever a browser pane exists.
        AppCommand(id: "chat.toggleLight", title: "Toggle Light Chat", symbol: "sun.max",
                   menuPath: ["Pane", "Chat"],
                   binding: KeyBinding("l", [.command, .control]),
                   isEnabled: { ShellWorkspace.chatStore(in: $0) != nil }) { store in
            ShellWorkspace.chatStore(in: store)?.toggleLight()
        },
    ]

    /// A browser pane's verbs, with the keys every browser on the Mac uses for them.
    ///
    /// All on ⌘, which a terminal never sees — so they are safe beside a shell — and each
    /// acts on the browser a URL would open in (the focused one, else the first) and on the
    /// tab that pane is showing, dimming when there is none. Except Open Location and New
    /// Browser Tab, which open a browser when there is none: ⌘L is how a page is asked for,
    /// and asking should not need a pane made first.
    static let browser: [AppCommand] = [
        AppCommand(id: "browser.openLocation", title: "Open Location", symbol: "globe",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("l", [.command]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0) != nil
                                || ShellWorkspace.canOpen(.browser, in: $0) }) { store in
            ShellWorkspace.openLocation(in: store)
        },
        // ⌃⌘T. ⌘T is New Session and ⌥⌘T a shell pane, so the browser's own "another
        // one of these" takes the third T — beside ⌃⌘N, the editor's new file.
        AppCommand(id: "browser.newTab", title: "New Browser Tab", symbol: "plus.square.on.square",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("t", [.command, .control]),
                   isEnabled: { ShellWorkspace.browserTabs(in: $0) != nil
                                || ShellWorkspace.canOpen(.browser, in: $0) }) { store in
            ShellWorkspace.newBrowserTab(in: store)
        },
        // ⌃⌘] and ⌃⌘[: the brackets are how every row in this app is walked — ⌘ for a
        // page's history, ⇧⌘ for the editor's tabs, ⌥⌘ for sessions — and ⌃⌘ was free.
        AppCommand(id: "browser.nextTab", title: "Next Browser Tab", symbol: "arrow.right.square",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("]", [.command, .control]),
                   isEnabled: { ShellWorkspace.browserTabs(in: $0)?.canClose ?? false }) { store in
            ShellWorkspace.withBrowserTabs(in: store) { $0.selectNext() }
        },
        AppCommand(id: "browser.previousTab", title: "Previous Browser Tab", symbol: "arrow.left.square",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("[", [.command, .control]),
                   isEnabled: { ShellWorkspace.browserTabs(in: $0)?.canClose ?? false }) { store in
            ShellWorkspace.withBrowserTabs(in: store) { $0.selectPrevious() }
        },
        // No chord. ⌘W closes the PANE and must go on meaning that; ⌃⌘W is the editor's
        // Close and ⇧⌃⌘W closes a session. The tab's own X, its context menu and the
        // palette are where this is. Dimmed on the last tab, which cannot be closed.
        AppCommand(id: "browser.closeTab", title: "Close Browser Tab", symbol: "xmark.square",
                   menuPath: ["Pane", "Browser"],
                   isEnabled: { ShellWorkspace.browserTabs(in: $0)?.canClose ?? false }) { store in
            ShellWorkspace.withBrowserTabs(in: store) { $0.closeSelected() }
        },
        AppCommand(id: "browser.reload", title: "Reload Page", symbol: "arrow.clockwise",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("r", [.command]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0)?.requestedURL != nil }) {
            ShellWorkspace.browserSession(in: $0)?.reload()
        },
        AppCommand(id: "browser.back", title: "Back", symbol: "chevron.backward",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("[", [.command]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0)?.canGoBack ?? false }) {
            ShellWorkspace.browserSession(in: $0)?.goBack()
        },
        AppCommand(id: "browser.forward", title: "Forward", symbol: "chevron.forward",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("]", [.command]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0)?.canGoForward ?? false }) {
            ShellWorkspace.browserSession(in: $0)?.goForward()
        },
        // ⌃⌘, the safest of the app's modifier sets: ⌘D and its variants are the splits,
        // and ⌃⌘D is the system's Look Up. L for light.
        AppCommand(id: "browser.toggleDark", title: "Toggle Dark Page", symbol: "moon",
                   menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("l", [.command, .control]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0) != nil }) {
            ShellWorkspace.browserSession(in: $0)?.toggleDark()
        },
        // ⌥⌘I, Safari's key for Web Inspector. The page is usually why the pane is open.
        AppCommand(id: "browser.inspect", title: "Show Web Inspector",
                   symbol: "wrench.and.screwdriver", menuPath: ["Pane", "Browser"],
                   binding: KeyBinding("i", [.command, .option]),
                   isEnabled: { ShellWorkspace.browserSession(in: $0)?.existingWebView != nil }) {
            ShellWorkspace.browserSession(in: $0)?.showInspector()
        },
        // No chord: Safari's ⌥⌘E is the Files pane here, and emptying caches is rare enough
        // for the menu and the palette.
        AppCommand(id: "browser.emptyCaches", title: "Empty Caches",
                   symbol: "arrow.trianglehead.2.clockwise", menuPath: ["Pane", "Browser"],
                   isEnabled: { ShellWorkspace.browserSession(in: $0) != nil }) {
            ShellWorkspace.browserSession(in: $0)?.emptyCaches()
        },
        AppCommand(id: "browser.openExternally", title: "Open in Default Browser",
                   symbol: "safari", menuPath: ["Pane", "Browser"],
                   isEnabled: { ShellWorkspace.browserSession(in: $0)?.requestedURL != nil }) {
            ShellWorkspace.browserSession(in: $0)?.openInDefaultBrowser()
        },
    ]

    /// The todo list's verbs that take the whole list at once. Palette and menu, no chord:
    /// Clear removes lines, and a chord that removes lines is a chord that gets hit; the
    /// progress bar is a look, and a look is set once.
    static let todo: [AppCommand] = [
        AppCommand(id: "todo.clearCompleted", title: "Clear Completed Tasks", symbol: "xmark.circle.fill",
                   menuPath: ["Pane", "Todo"],
                   isEnabled: { (ShellWorkspace.todoStore(in: $0)?.document.completedCount ?? 0) > 0 }) {
            ShellWorkspace.todoStore(in: $0)?.removeCompleted()
        },
        // The bar's own close control hides it; this is how it comes back without the
        // pointer, and the footer's toggle is the same verb.
        AppCommand(id: "todo.toggleProgress", title: "Toggle Progress Bar", symbol: "percent",
                   menuPath: ["Pane", "Todo"],
                   isEnabled: { ShellWorkspace.todoStore(in: $0) != nil }) {
            ShellWorkspace.todoStore(in: $0)?.toggleProgress()
        },
        // The chevron on each heading folds one section; these are the key path, all at once.
        AppCommand(id: "todo.collapseAll", title: "Collapse All Sections", symbol: "chevron.right",
                   menuPath: ["Pane", "Todo"],
                   isEnabled: { ShellWorkspace.todoStore(in: $0)?.canCollapseAll ?? false }) {
            ShellWorkspace.todoStore(in: $0)?.collapseAll()
        },
        AppCommand(id: "todo.expandAll", title: "Expand All Sections", symbol: "chevron.down",
                   menuPath: ["Pane", "Todo"],
                   isEnabled: { ShellWorkspace.todoStore(in: $0)?.canExpandAll ?? false }) {
            ShellWorkspace.todoStore(in: $0)?.expandAll()
        },
        // Asks first — see `removeAllAfterConfirming` — hence the ellipsis. The footer's z
        // beside the list's path is the same verb.
        AppCommand(id: "todo.clearAll", title: "Clear Todo List…", symbol: "minus.circle.fill",
                   menuPath: ["Pane", "Todo"], keywords: ["Delete All Tasks", "Empty List"],
                   isEnabled: { !(ShellWorkspace.todoStore(in: $0)?.document.isBlank ?? true) }) {
            ShellWorkspace.todoStore(in: $0)?.removeAllAfterConfirming()
        },
    ]

    /// The context list's verbs. Quick Look is Space in the pane, as it is in Finder, and
    /// Finder's ⌘Y here, since a plain key cannot be a menu item: the pane has to have the
    /// keyboard for Space to mean anything, and the menu is how it gets there from anywhere.
    static let context: [AppCommand] = [
        AppCommand(id: "context.quickLook", title: "Quick Look", symbol: "eye",
                   menuPath: ["Pane", "Context"],
                   binding: KeyBinding("y", [.command]),
                   keywords: ["Preview", "Space"],
                   isEnabled: { ShellWorkspace.contextModel(in: $0)?.previewableItems.isEmpty == false }) {
            ShellWorkspace.quickLook(in: $0)
        },
    ]

    /// A simulator pane's verbs. They act on the simulator pane a device would open in —
    /// the focused one, else the first — and dim when there is none.
    ///
    /// ⇧⌘H is Home, the key the Simulator app has always used; ⌃⌘=, ⌃⌘- and ⌃⌘0 zoom;
    /// ⌃⌥⌘← and ⌃⌥⌘→ turn the device and ⌃⌥⌘F folds one that folds. The rest have no
    /// chord: a pane's worth of device buttons is found in the palette, not memorised.
    static let simulator: [AppCommand] = [
        AppCommand(id: "simulator.home", title: "Home", symbol: "house",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("h", [.command, .shift]),
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canPress ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.pressHome()
        },
        AppCommand(id: "simulator.lock", title: "Lock", symbol: "lock",
                   menuPath: ["Pane", "Simulator"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canPress ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.pressLock()
        },
        AppCommand(id: "simulator.boot", title: "Boot Device", symbol: "power",
                   menuPath: ["Pane", "Simulator"],
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.device != nil && !session.isBooted && !session.isBusy
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.boot()
        },
        AppCommand(id: "simulator.shutdown", title: "Shut Down Device", symbol: "power.circle",
                   menuPath: ["Pane", "Simulator"],
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.isBooted && !session.isBusy
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.shutdown()
        },
        // ⌃⌥⌘ and an arrow: ⌥⌘ moves focus between panes and ⌃⌘ grows one, so the one
        // arrow chord left is the one that turns the device. Simulator's own ⌘← is a
        // shell's start-of-line and an editor's.
        AppCommand(id: "simulator.rotateLeft", title: "Rotate Left", symbol: "rotate.left",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding(.leftArrow, [.command, .option, .control]),
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canMove ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.rotateLeft()
        },
        AppCommand(id: "simulator.rotateRight", title: "Rotate Right", symbol: "rotate.right",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding(.rightArrow, [.command, .option, .control]),
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canMove ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.rotateRight()
        },
        AppCommand(id: "simulator.fold", title: "Fold or Unfold Device", symbol: "book",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("f", [.command, .option, .control]),
                   keywords: ["Open Device", "Close Device", "Flip", "iPhone Duo"],
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.isFoldable && session.canMove
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.toggleFold()
        },
        // Whether a click uses the device or turns it. ⌃⌘E: ⌘E is the shell's and the
        // editor's, ⌥⌘E is taken, and ⌃⌘ is this pane's own row (⌃⌘L, ⌃⌘0).
        AppCommand(id: "simulator.toggleMode", title: "Toggle Edit / Preview", symbol: "eye",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("e", [.command, .control]),
                   keywords: ["Preview Mode", "Edit Mode", "Interact", "Operate", "Turn Device"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.device != nil }) {
            ShellWorkspace.simulatorSession(in: $0)?.toggleMode()
        },
        // The finish, round the palette. The dots over the device are the pointer's way.
        AppCommand(id: "simulator.nextFinish", title: "Next Finish", symbol: "paintpalette",
                   menuPath: ["Pane", "Simulator"], keywords: ["Colour", "Color", "Device Colour"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canChangeFinish ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.nextFinish()
        },
        AppCommand(id: "simulator.previousFinish", title: "Previous Finish", symbol: "paintpalette",
                   menuPath: ["Pane", "Simulator"], keywords: ["Colour", "Color", "Device Colour"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.canChangeFinish ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.previousFinish()
        },
        AppCommand(id: "simulator.frame", title: "Toggle Device Frame", symbol: "iphone.gen3",
                   menuPath: ["Pane", "Simulator"],
                   keywords: ["Bezel", "Enclosure", "Chrome"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.device != nil }) {
            ShellWorkspace.simulatorSession(in: $0)?.toggleFrame()
        },
        AppCommand(id: "simulator.screenshot", title: "Take Screenshot", symbol: "camera",
                   menuPath: ["Pane", "Simulator"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.isBooted ?? false }) { store in
            guard let session = ShellWorkspace.simulatorSession(in: store) else { return }
            Task { await session.takeScreenshot() }
        },
        AppCommand(id: "simulator.appearance", title: "Toggle Dark Appearance", symbol: "moon",
                   menuPath: ["Pane", "Simulator"],
                   isEnabled: { ShellWorkspace.simulatorSession(in: $0)?.isBooted ?? false }) {
            ShellWorkspace.simulatorSession(in: $0)?.toggleAppearance()
        },
        // ⌃⌘ rather than ⌘: ⌘= is Equalize Panes, and ⌘0–9 pick panes. ⌃⌘ is the safest
        // range beside a terminal, and a device being looked at closely is worth a chord.
        AppCommand(id: "simulator.zoomIn", title: "Zoom In on Device", symbol: "plus.magnifyingglass",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("=", [.command, .control]),
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.device != nil && session.canZoomIn
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.zoomIn()
        },
        AppCommand(id: "simulator.zoomOut", title: "Zoom Out on Device", symbol: "minus.magnifyingglass",
                   menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("-", [.command, .control]),
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.device != nil && session.canZoomOut
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.zoomOut()
        },
        AppCommand(id: "simulator.zoomToFit", title: "Fit Device to Pane",
                   symbol: "arrow.down.right.and.arrow.up.left", menuPath: ["Pane", "Simulator"],
                   binding: KeyBinding("0", [.command, .control]),
                   isEnabled: { store in
                       guard let session = ShellWorkspace.simulatorSession(in: store) else { return false }
                       return session.device != nil && !session.isFitted
                   }) {
            ShellWorkspace.simulatorSession(in: $0)?.zoomToFit()
        },
    ]

    /// Starting a file that does not exist yet.
    ///
    /// In the registry, unlike the rest of the Editor menu, because it acts on the LAYOUT:
    /// it lands in the editor a clicked file would have landed in, and opens one when there
    /// is none — which is why it never dims for want of an editor, only for want of room.
    /// Its first save offers the project's `.ultra/` folder.
    ///
    /// ⌃⌘N is the fourth kind of new, after ⌘N (window), ⇧⌘N (project) and ⌥⌘N (chat).
    static let editor: [AppCommand] = [
        AppCommand(id: "editor.newFile", title: "New File", symbol: "doc.badge.plus",
                   menuPath: ["Pane", "Editor"],
                   binding: KeyBinding("n", [.command, .control]),
                   isEnabled: { ShellWorkspace.editorSessions(in: $0) != nil
                                || ShellWorkspace.canOpen(.editor, in: $0) }) { store in
            ShellWorkspace.showInEditor(.newFile, in: store)
        },
        // ⌃⌘L, the browser's and the chat's key for the same thing, shared on purpose: one
        // key for "this pane, light or not". Like the chat's, this one is enabled only
        // with an editor FOCUSED, so the menu fires the one for the pane in hand.
        AppCommand(id: "editor.toggleLight", title: "Toggle Light Editor", symbol: "sun.max",
                   menuPath: ["Pane", "Editor"],
                   binding: KeyBinding("l", [.command, .control]),
                   isEnabled: { ShellWorkspace.focusedEditorSessions(in: $0) != nil }) { store in
            ShellWorkspace.focusedEditorSessions(in: store)?.toggleLight()
        },
        // ⌃⌘R: a Markdown file's page or its text. Enabled only with a Markdown file
        // showing in the focused editor, the one file kind that has both.
        AppCommand(id: "editor.toggleReading", title: "Toggle Reading Mode", symbol: "book",
                   menuPath: ["Pane", "Editor"],
                   binding: KeyBinding("r", [.command, .control]),
                   isEnabled: { ShellWorkspace.focusedEditorSessions(in: $0)?.readableDocument != nil }) { store in
            ShellWorkspace.focusedEditorSessions(in: store)?.toggleReading()
        },
    ]

    /// Verbs about the arrangement as a whole. Palette and menu only: a command that
    /// rewrites a project's layout is not one to have on a chord.
    static let layouts: [AppCommand] = [
        AppCommand(id: "layout.setDefault", title: "Set as Default Layout",
                   symbol: "pin", menuPath: ["Pane"],
                   isEnabled: { $0.workspaceDirectory != nil }) { store in
            SharedLayout.setDefault(from: store)
        },
        AppCommand(id: "layout.resetToDefault", title: "Use Default Layout…",
                   symbol: "arrow.uturn.backward", menuPath: ["Pane"],
                   isEnabled: { SharedLayout.hasDefault(for: $0) }) { store in
            SharedLayout.resetToDefault(store)
        },
        AppCommand(id: "layout.applyToAllProjects", title: "Apply Layout to All Projects…",
                   symbol: "square.on.square", menuPath: ["Pane"],
                   isEnabled: { $0.workspaceDirectory != nil }) { store in
            SharedLayout.applyToAllProjects(from: store)
        },
    ]

    /// Opening and switching pane kinds. Palette-only: seven kinds times two verbs is
    /// fourteen bindings nobody would remember, and the kinds that earn a shortcut declare
    /// it on the menu item instead (`TileShortcut`). On the menu they are Pane ▸ New Pane
    /// and Pane ▸ Change Pane To, where the title is just the kind.
    static let paneKinds: [AppCommand] =
        PaneKind.offered.filter { $0.kind != .shell }.map { entry in
            AppCommand(id: "pane.new.\(entry.kind.rawValue)",
                       title: "New \(entry.title) Pane",
                       symbol: entry.symbol,
                       menuPath: ["Pane", "New Pane"],
                       binding: nil,
                       isEnabled: { ShellWorkspace.canOpen(entry.kind, in: $0) }) { store in
                ShellWorkspace.openTile(entry.kind, in: store)
            }
        }
        + PaneKind.offered.map { entry in
            AppCommand(id: "pane.change.\(entry.kind.rawValue)",
                       title: "Change Pane to \(entry.title)",
                       symbol: entry.symbol,
                       menuPath: ["Pane", "Change Pane To"],
                       binding: nil,
                       isEnabled: { store in
                           // Not on the Agents overview: a pane is converted at home,
                           // where the factories that build the replacement live.
                           !store.isFixedArrangement
                               && store.surfaces.records[store.tree.focused]?.kind != entry.kind
                       }) { store in
                ShellWorkspace.convert(store.tree.focused, to: entry.kind, in: store)
            }
        }

    /// Pointing a tile at a different folder, without the pointer.
    ///
    /// The footer's folder menu is the discoverable path; these are the same four verbs on
    /// the menu bar, so they reach a tile while a full-screen TUI owns the keyboard. No
    /// default bindings: four more chords for a control most panes do not have would be four
    /// chords nobody remembers — the palette is how these are found.
    static let folders: [AppCommand] = [
        AppCommand(id: "pane.folder.choose", title: "Set Pane Folder…",
                   symbol: "folder", menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
            guard let root = ShellWorkspace.tileRoot(store.tree.focused, in: store),
                  let url = chooseTileFolder(title: "Pane Folder", directory: root) else { return }
            ShellWorkspace.setFolder(url, of: store.tree.focused, in: store)
        },
        AppCommand(id: "pane.folder.up", title: "Pane Folder: Go Up",
                   symbol: "arrow.turn.left.up", menuPath: ["Pane", "Folder"],
                   isEnabled: { store in
                       guard canRetargetFocused(store),
                             let root = ShellWorkspace.tileRoot(store.tree.focused, in: store)
                       else { return false }
                       return root.deletingLastPathComponent().path != root.path
                   }) { store in
            guard let root = ShellWorkspace.tileRoot(store.tree.focused, in: store) else { return }
            ShellWorkspace.setFolder(root.deletingLastPathComponent(),
                                     of: store.tree.focused, in: store)
        },
        AppCommand(id: "pane.folder.shell", title: "Pane Folder: Follow Shell",
                   symbol: "apple.terminal", menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
            let shell = ShellWorkspace.Registry
                .workingDirectory(in: store.workspaceID,
                                  fallback: ShellWorkspace.projectFolder(of: store))
            ShellWorkspace.setFolder(shell, of: store.tree.focused, in: store)
        },
        AppCommand(id: "pane.folder.project", title: "Pane Folder: Project Folder",
                   symbol: "house", menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
            ShellWorkspace.setFolder(ShellWorkspace.projectFolder(of: store),
                                     of: store.tree.focused, in: store)
        },
    ]

    /// Dimmed rather than hidden on a pane with no folder of its own — a command that
    /// vanishes is a command nobody learns.
    private static let canRetargetFocused: @MainActor (LayoutStore) -> Bool = { store in
        ShellWorkspace.canSetFolder(store.tree.focused, in: store)
    }

    static let splits: [AppCommand] = [
        AppCommand(id: "pane.split.right", title: "Split Right",
                   symbol: "rectangle.righthalf.inset.filled", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command])) { $0.split(edge: .right) },
        AppCommand(id: "pane.split.down", title: "Split Down",
                   symbol: "rectangle.bottomhalf.inset.filled", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .shift])) { $0.split(edge: .bottom) },
        AppCommand(id: "pane.split.left", title: "Split Left",
                   symbol: "rectangle.lefthalf.inset.filled", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .option])) { $0.split(edge: .left) },
        AppCommand(id: "pane.split.up", title: "Split Up",
                   symbol: "rectangle.tophalf.inset.filled", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .option, .shift])) { $0.split(edge: .top) },
    ]

    static let focusMoves: [AppCommand] = [
        (Edge.left, KeyEquivalent.leftArrow), (.right, .rightArrow),
        (.top, .upArrow), (.bottom, .downArrow),
    ].map { edge, key in
        AppCommand(id: "pane.focus.\(edge.rawValue)",
                   title: "Focus \(edge.actionName)",
                   symbol: "arrow.\(edge.actionName.lowercased())",
                   menuPath: ["Pane", "Focus"],
                   binding: KeyBinding(key, [.command, .option])) { $0.moveFocus(edge) }
    }

    /// The keyboard path to what a pane drag does on its swap zone — and the only drop
    /// there is on the Agents overview, whose grid trades places and nothing else.
    static let swaps: [AppCommand] = [
        (Edge.left, KeyEquivalent.leftArrow), (.right, .rightArrow),
        (.top, .upArrow), (.bottom, .downArrow),
    ].map { edge, key in
        AppCommand(id: "pane.swap.\(edge.rawValue)",
                   title: "Swap \(edge.actionName)",
                   symbol: edge == .left || edge == .right ? "arrow.left.arrow.right" : "arrow.up.arrow.down",
                   menuPath: ["Pane", "Swap"],
                   binding: KeyBinding(key, [.command, .option, .shift]),
                   keywords: ["Move Pane", "Trade Places"]) { $0.swapFocused(edge) }
    }

    static let resizes: [AppCommand] = [
        (Edge.left, KeyEquivalent.leftArrow), (.right, .rightArrow),
        (.top, .upArrow), (.bottom, .downArrow),
    ].map { edge, key in
        AppCommand(id: "pane.resize.\(edge.rawValue)",
                   title: "Grow \(edge.actionName)",
                   symbol: "arrow.\(edge.actionName.lowercased()).to.line",
                   menuPath: ["Pane", "Resize"],
                   binding: KeyBinding(key, [.command, .control])) { $0.resizeFocused(edge, by: 16) }
    }

    /// Visual order, not tree order — the number the user counts on screen is the number
    /// they press.
    static let numbered: [AppCommand] = (1...9).map { number in
        AppCommand(id: "pane.focus.index.\(number)",
                   title: "Focus Pane \(number)",
                   symbol: "\(number).square",
                   menuPath: ["Pane", "Focus"],
                   binding: KeyBinding(KeyEquivalent(Character("\(number)")), [.command]),
                   isEnabled: { $0.layoutResult.visualOrder.count >= number }) {
            $0.focusPane(atVisualIndex: number - 1)
        }
    }

    /// Side-by-side panes shared out evenly: three columns a third each, four a quarter.
    ///
    /// Named, not just a row in `others`, because the window bar's ellipsis menu leads with
    /// it. Widths only — the heights of panes stacked inside a column are left alone, which
    /// is what tells it apart from Equalize All Panes. No chord: ⌘= and ⌥⌘= are its two
    /// siblings, and ⇧⌘= is ⌘+, which a terminal user reads as "bigger text".
    static let equalizeColumns = AppCommand(
        id: "pane.equalizeColumns", title: "Equalize Column Widths",
        symbol: "rectangle.split.3x1", menuPath: ["Pane"],
        isEnabled: { $0.tree.hasContainer(along: .horizontal) }) { $0.equalizeColumns() }

    /// The same for stacked panes: two in a column come out half each, three a third, and
    /// nothing side by side moves. Named for the same reason as its partner, and found by
    /// "column heights" as well, since the panes it evens out are the ones IN a column.
    static let equalizeRows = AppCommand(
        id: "pane.equalizeRows", title: "Equalize Row Heights",
        symbol: "rectangle.split.1x2", menuPath: ["Pane"],
        keywords: ["Equalize Column Heights", "Equal Heights"],
        isEnabled: { $0.tree.hasContainer(along: .vertical) }) { $0.equalizeRows() }

    static let others: [AppCommand] = [
        // Enabled even on the LAST pane, where it closes the project instead.
        //
        // The alternative was to dim it there, and that makes ⌘W a dead key on exactly the
        // window a new user starts with — the one-pane one. Closing the smallest thing you
        // are inside is what ⌘W means everywhere else, and when the pane IS the project,
        // the project is the smallest thing: its session closes, and the window goes on
        // to the next one. No question asked, unlike Close Session: what stops is this one
        // pane, which is what ⌘W stops every other time.
        //
        // The last session cannot close (`SessionList.canCloseSelected`), so there the
        // pane is the window too. With another window showing a project, this one closes
        // and that one is where the keyboard goes; with none, the app quits — a window
        // closed instead left the app running with nothing on screen, its shells still
        // going where no window showed them. `performClose` rather than a direct close, so
        // the window still runs its own teardown: scrollback saved, layout persisted. A
        // quit saves the same way, and the project reopens on the next launch.
        AppCommand(id: "pane.close", title: "Close Pane", symbol: "xmark", menuPath: ["Pane"],
                   binding: KeyBinding("w", [.command])) { store in
            guard store.tree.paneCount > 1 else {
                // A pane window's last pane: the window closes, and the pane goes back to
                // the main window still running — closing a pane window stops nothing.
                if store.isPaneWindow {
                    if let window = PaneWindows.window(for: store) {
                        window.performClose(nil)
                    } else {
                        store.returnAllPanes()
                    }
                    return
                }
                let sessions = SessionList.holding(store)
                if let sessions, sessions.canCloseSelected {
                    sessions.close(store.workspaceID)
                } else if sessions?.othersAreShowingSessions ?? true {
                    ShellWorkspace.Registry.windows[store.workspaceID]?.performClose(nil)
                } else {
                    NSApp.terminate(nil)
                }
                return
            }
            store.closeFocused()
        },
        // The toast's close control, as a command, so a notice can be put away without
        // reaching for the pointer. No key of its own: ⎋ belongs to the palette and to
        // whatever TUI has the keyboard, and a notice is rare enough that the palette is
        // the right way to it.
        AppCommand(id: "pane.dismissNotice", title: "Dismiss Notice", symbol: "xmark.circle",
                   menuPath: ["Pane"],
                   isEnabled: { ShellWorkspace.dismissNotice(in: $0) != nil }) { store in
            ShellWorkspace.dismissNotice(in: store)?()
        },
        // A pane in a window of its own, still in its session: same shell, same project.
        // ⇧⌘M both ways — out from the main window, back from a pane window — because only
        // one of the two is ever enabled, the way ⌃⌘L is shared by the chat and the browser.
        AppCommand(id: "pane.moveToNewWindow", title: "Move Pane to New Window",
                   symbol: "macwindow.badge.plus", menuPath: ["Pane"],
                   binding: KeyBinding("m", [.command, .shift]),
                   keywords: ["Detach Pane", "Pop Out Pane", "Tear Off Pane"],
                   isEnabled: { $0.canMoveToNewWindow() }) { $0.moveToNewWindow() },
        AppCommand(id: "pane.moveBackToMainWindow", title: "Move Pane Back to Main Window",
                   symbol: "arrow.up.right.and.arrow.down.left", menuPath: ["Pane"],
                   binding: KeyBinding("m", [.command, .shift]),
                   keywords: ["Attach Pane", "Return Pane"],
                   isEnabled: { $0.isPaneWindow }) { $0.moveBackToMainWindow() },
        AppCommand(id: "pane.zoom", title: "Toggle Zoom",
                   symbol: "arrow.up.left.and.arrow.down.right", menuPath: ["Pane"],
                   binding: KeyBinding(.return, [.command, .shift]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.toggleZoom() },
        AppCommand(id: "pane.equalize", title: "Equalize Panes", symbol: "equal", menuPath: ["Pane"],
                   binding: KeyBinding("=", [.command]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.equalizeFocusedContainer() },
        AppCommand(id: "pane.equalizeAll", title: "Equalize All Panes", symbol: "equal.square",
                   menuPath: ["Pane"],
                   binding: KeyBinding("=", [.command, .option]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.equalizeAll() },
        equalizeColumns,
        equalizeRows,
    ]

    /// No default binding may shadow a key the shell owns. Checked at launch in debug
    /// builds rather than trusted to review.
    static func assertNoTerminalConflicts() {
        for command in all {
            // A palette-only command has no binding by design, so it cannot shadow anything.
            guard let binding = command.defaultBinding else { continue }
            assert(!ReservedTerminalKeys.conflicts(binding),
                   "\(command.id) binds \(binding.display), which a terminal owns")
        }
    }

    /// Every symbol must be one this OS ships. A misspelt name does not fail — SwiftUI
    /// draws nothing — so the palette would show a blank slot that nobody notices until a
    /// user does. Checked at launch in debug builds, beside the binding check.
    static func assertEverySymbolResolves() {
        for command in all {
            assert(NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) != nil,
                   "\(command.id) names symbol \"\(command.symbol)\", which does not exist")
        }
    }
}

/// Builds the Pane menu from the registry. A command that cannot run is DIMMED, never
/// hidden — a disappearing command is unlearnable.
struct PaneMenuCommands: Commands {
    /// The focused TAB's store. Captured per-event rather than at launch, because with tabs
    /// there is no single store the Pane menu could belong to.
    @FocusedValue(\.layoutStore) private var store

    private func item(_ command: AppCommand) -> some View {
        Button(command.title) { if let store { command.run(store) } }
            .disabled(store.map { !command.isEnabled($0) } ?? true)
            .modifier(BindingModifier(binding: command.defaultBinding))
    }

    /// What the focused pane is right now, so Change Pane To can dim the entry the user
    /// is already looking at.
    private var currentKind: PaneRecord.Kind? {
        guard let store else { return nil }
        return store.surfaces.records[store.tree.focused]?.kind
    }

    private var canOpenNewPane: Bool {
        store.map { ShellWorkspace.canOpenNewPane(in: $0) } ?? false
    }

    var body: some Commands {
        CommandMenu("Pane") {
            // Another pane, of any kind, in one list: a shell, then the project's agents by
            // name, then every tile. These sat on File as five items — New Shell Pane, New
            // Agent Pane, New Tile Pane, Change Pane To, Change Pane to Agent — between
            // opening a project and closing a window, which is not where a pane lives.
            Menu("New Pane") {
              if store?.isFixedArrangement == true {
                // On the Agents overview: an agent in one of the open projects, which is
                // the only pane that can come to it. The window bar's `+` says the same.
                AgentProjectsMenuItems()
              } else {
                Button("Shell") {
                    guard let store else { return }
                    ShellWorkspace.openShell(in: store)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                // Each agent by name. The FIRST installed one is the default — what ⌥⌘A
                // and "New Agent Pane" in the palette open — and it carries the key so the
                // menu teaches it. An agent that is not installed stays in the list,
                // dimmed, with the binary it was looking for: hidden, it would look like
                // the project had forgotten it.
                let agents = store.map(ShellWorkspace.agents(in:)) ?? []
                let preferred = store.flatMap(ShellWorkspace.defaultAgent(in:))
                ForEach(agents) { agent in
                    let available = ShellWorkspace.isAvailable(agent)
                    Button(agent.name) {
                        guard let store else { return }
                        ShellWorkspace.openShell(agent: agent, in: store)
                    }
                    .modifier(AgentShortcut(isDefault: agent == preferred))
                    .disabled(!available)
                    .help(available ? agent.command : "\(agent.binary) is not installed")
                }
                if agents.isEmpty {
                    Text("No agents — add one under Customize")
                }

                Divider()

                // Every tile kind, from one list — a new kind must not need three separate
                // edits to become openable.
                ForEach(PaneKind.offered.filter { !$0.isShell }) { entry in
                    Button(entry.title) {
                        guard let store else { return }
                        ShellWorkspace.openTile(entry.kind, in: store)
                    }
                    .modifier(TileShortcut(kind: entry.kind))
                }
              }
            }
            .disabled(!canOpenNewPane && store?.isFixedArrangement != true)

            // Switching an EXISTING pane, rather than opening another one. Separate on
            // purpose: converting a shell ends its process, which is not something to
            // discover by picking the wrong menu item. The same three sections as New
            // Pane: the agents by name are for a project with more than one — "Agent"
            // alone would take the default.
            Menu("Change Pane To") {
                ForEach(PaneKind.offered.filter { $0.kind != .agent }) { entry in
                    Button(entry.title) {
                        guard let store else { return }
                        ShellWorkspace.convert(store.tree.focused, to: entry.kind, in: store)
                    }
                    .disabled(currentKind == entry.kind)
                }
                let agents = store.map(ShellWorkspace.agents(in:)) ?? []
                if !agents.isEmpty {
                    Divider()
                }
                ForEach(agents) { agent in
                    Button(agent.name) {
                        guard let store else { return }
                        ShellWorkspace.convert(store.tree.focused, toAgent: agent, in: store)
                    }
                    .disabled(!ShellWorkspace.isAvailable(agent))
                }
            }
            .disabled(store == nil)

            Divider()
            ForEach(PaneCommands.splits) { item($0) }
            Divider()
            ForEach(PaneCommands.others) { item($0) }
            Divider()
            ForEach(PaneCommands.prompt) { item($0) }
            Divider()
            Menu("Focus") {
                ForEach(PaneCommands.focusMoves) { item($0) }
                Divider()
                ForEach(PaneCommands.numbered) { item($0) }
            }
            Menu("Swap") {
                ForEach(PaneCommands.swaps) { item($0) }
            }
            Menu("Resize") {
                ForEach(PaneCommands.resizes) { item($0) }
            }
            Menu("Folder") {
                ForEach(PaneCommands.folders) { item($0) }
            }
            Menu("Chat") {
                ForEach(PaneCommands.chat) { item($0) }
            }
            Menu("Browser") {
                ForEach(PaneCommands.browser) { item($0) }
            }
            if TileFactory.offersSimulator {
                Menu("Simulator") {
                    ForEach(PaneCommands.simulator) { item($0) }
                }
            }
            Menu("Todo") {
                ForEach(PaneCommands.todo) { item($0) }
            }
            Menu("Context") {
                ForEach(PaneCommands.context) { item($0) }
            }
            Divider()
            ForEach(PaneCommands.layouts) { item($0) }
            Divider()
            // The editor's tab commands are not in the command registry with everything
            // else, and deliberately: every `AppCommand` acts on a `LayoutStore`, and these act on one
            // pane's `EditorSessions`. Bending the registry to carry both would make every
            // other command's signature pay for it.
            Menu("Editor") {
                ForEach(PaneCommands.editor) { item($0) }
                Divider()
                editorItems
            }
        }
    }

    /// Every one keeps ⌘, which is what makes them safe: `ReservedTerminalKeys` treats
    /// anything with ⌘ as ours, and a shell pane keeps every ⌃ and ⌥ chord it expects.
    ///
    /// NOT ⌘W for closing. That already closes the pane — the arrangement Terminal and iTerm
    /// settled on, with ⌘⇧W for the window — and quietly making it mean "close what is open,
    /// unless it is the last one" is how a keystroke someone relies on starts doing something
    /// else.
    ///
    /// Next and Previous are the keyboard route along the tab strip, for the reason the
    /// `keyboard-first` skill gives: a tab reachable only by pointer is an action this app
    /// does not actually have.
    @ViewBuilder private var editorItems: some View {
        let sessions = store.flatMap(ShellWorkspace.editorSessions(in:))
        Button("Next") { sessions?.selectNext() }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((sessions?.sessions.count ?? 0) < 2)
        Button("Previous") { sessions?.selectPrevious() }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((sessions?.sessions.count ?? 0) < 2)
        Divider()
        Button("Close") { sessions?.closeSelected() }
            .keyboardShortcut("w", modifiers: [.command, .control])
            .disabled(sessions?.selected == nil)
    }
}

private struct BindingModifier: ViewModifier {
    let binding: KeyBinding?

    func body(content: Content) -> some View {
        if let binding {
            content.keyboardShortcut(binding.key, modifiers: binding.modifiers)
        } else {
            content
        }
    }
}

/// Default shortcuts for the pane kinds that earn one. Kinds without a binding are still
/// reachable from the menu and the palette — a shortcut nobody can remember is not a feature.
/// ⌥⌘A on the default agent only. Beside ⌥⌘T for a shell: the two kinds of pane that
/// run something. ⌃A alone is readline's start-of-line and ⌘A is Select All, so the pair
/// with ⌥ is the free one.
private struct AgentShortcut: ViewModifier {
    let isDefault: Bool

    func body(content: Content) -> some View {
        if isDefault {
            content.keyboardShortcut("a", modifiers: [.command, .option])
        } else {
            content
        }
    }
}

private struct TileShortcut: ViewModifier {
    let kind: PaneRecord.Kind

    func body(content: Content) -> some View {
        switch kind {
        case .fileTree: content.keyboardShortcut("e", modifiers: [.command, .option])
        case .todo: content.keyboardShortcut("y", modifiers: [.command, .option])
        case .git: content.keyboardShortcut("g", modifiers: [.command, .option])
        case .chat: content.keyboardShortcut("c", modifiers: [.command, .option])
        case .browser: content.keyboardShortcut("b", modifiers: [.command, .option])
        // P for phone. ⌥⌘S is the sidebar.
        case .simulator: content.keyboardShortcut("p", modifiers: [.command, .option])
        default: content
        }
    }
}
