import SwiftUI
import UltraCanvas
import UltraCore
import UltraLayout
import UltraTiles

/// Every pane verb, declared once.
///
/// These are declared on the MAIN MENU rather than on a view, and that is load-bearing:
/// `NSApp.mainMenu.performKeyEquivalent` runs before the key window's first responder sees
/// the event, so these fire even while a full-screen TUI owns the keyboard. A
/// `.keyboardShortcut` on a view inside a pane would never see the key.
enum PaneCommands {

    static let all: [AppCommand] = splits + focusMoves + resizes + numbered + others
                                 + paneKinds + folders

    /// Opening and switching pane kinds. Palette-only: seven kinds times two verbs is
    /// fourteen bindings nobody would remember, and the three that earn a shortcut declare
    /// it on the menu item instead.
    static let paneKinds: [AppCommand] =
        PaneKind.all.filter { $0.kind != .shell }.map { entry in
            AppCommand(id: "pane.new.\(entry.kind.rawValue)",
                       title: "New \(entry.title) Pane",
                       menuPath: ["File"],
                       binding: nil,
                       isEnabled: { ShellWorkspace.canOpenNewPane(in: $0) }) { store in
                ShellWorkspace.openTile(entry.kind, in: store)
            }
        }
        + PaneKind.all.map { entry in
            AppCommand(id: "pane.change.\(entry.kind.rawValue)",
                       title: "Change Pane to \(entry.title)",
                       menuPath: ["File"],
                       binding: nil,
                       isEnabled: { store in
                           store.surfaces.records[store.tree.focused]?.kind != entry.kind
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
                   menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
            guard let root = ShellWorkspace.tileRoot(store.tree.focused, in: store),
                  let url = chooseTileFolder(title: "Pane Folder", directory: root) else { return }
            ShellWorkspace.setFolder(url, of: store.tree.focused, in: store)
        },
        AppCommand(id: "pane.folder.up", title: "Pane Folder: Go Up",
                   menuPath: ["Pane", "Folder"],
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
                   menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
            let shell = ShellWorkspace.Registry
                .workingDirectory(in: store.workspaceID,
                                  fallback: ShellWorkspace.projectFolder(of: store))
            ShellWorkspace.setFolder(shell, of: store.tree.focused, in: store)
        },
        AppCommand(id: "pane.folder.project", title: "Pane Folder: Project Folder",
                   menuPath: ["Pane", "Folder"], isEnabled: canRetargetFocused) { store in
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
        AppCommand(id: "pane.split.right", title: "Split Right", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command])) { $0.split(edge: .right) },
        AppCommand(id: "pane.split.down", title: "Split Down", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .shift])) { $0.split(edge: .bottom) },
        AppCommand(id: "pane.split.left", title: "Split Left", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .option])) { $0.split(edge: .left) },
        AppCommand(id: "pane.split.up", title: "Split Up", menuPath: ["Pane", "Split"],
                   binding: KeyBinding("d", [.command, .option, .shift])) { $0.split(edge: .top) },
    ]

    static let focusMoves: [AppCommand] = [
        (Edge.left, KeyEquivalent.leftArrow), (.right, .rightArrow),
        (.top, .upArrow), (.bottom, .downArrow),
    ].map { edge, key in
        AppCommand(id: "pane.focus.\(edge.rawValue)",
                   title: "Focus \(edge.actionName)",
                   menuPath: ["Pane", "Focus"],
                   binding: KeyBinding(key, [.command, .option])) { $0.moveFocus(edge) }
    }

    static let resizes: [AppCommand] = [
        (Edge.left, KeyEquivalent.leftArrow), (.right, .rightArrow),
        (.top, .upArrow), (.bottom, .downArrow),
    ].map { edge, key in
        AppCommand(id: "pane.resize.\(edge.rawValue)",
                   title: "Grow \(edge.actionName)",
                   menuPath: ["Pane", "Resize"],
                   binding: KeyBinding(key, [.command, .control])) { $0.resizeFocused(edge, by: 16) }
    }

    /// Visual order, not tree order — the number the user counts on screen is the number
    /// they press.
    static let numbered: [AppCommand] = (1...9).map { number in
        AppCommand(id: "pane.focus.index.\(number)",
                   title: "Focus Pane \(number)",
                   menuPath: ["Pane", "Focus"],
                   binding: KeyBinding(KeyEquivalent(Character("\(number)")), [.command]),
                   isEnabled: { $0.layoutResult.visualOrder.count >= number }) {
            $0.focusPane(atVisualIndex: number - 1)
        }
    }

    static let others: [AppCommand] = [
        // Enabled even on the LAST pane, where it closes the window instead.
        //
        // The alternative was to dim it there, and that makes ⌘W a dead key on exactly the
        // window a new user starts with — the one-pane one. Closing the smallest thing you
        // are inside is what ⌘W means everywhere else, and when the pane IS the window, the
        // window is the smallest thing. `performClose` rather than a direct close, so the
        // window still runs its own teardown: scrollback saved, layout persisted.
        AppCommand(id: "pane.close", title: "Close Pane", menuPath: ["Pane"],
                   binding: KeyBinding("w", [.command])) { store in
            guard store.tree.paneCount > 1 else {
                ShellWorkspace.Registry.windows[store.workspaceID]?.performClose(nil)
                return
            }
            store.closeFocused()
        },
        AppCommand(id: "pane.zoom", title: "Toggle Zoom", menuPath: ["Pane"],
                   binding: KeyBinding(.return, [.command, .shift]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.toggleZoom() },
        AppCommand(id: "pane.equalize", title: "Equalize Panes", menuPath: ["Pane"],
                   binding: KeyBinding("=", [.command]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.equalizeFocusedContainer() },
        AppCommand(id: "pane.equalizeAll", title: "Equalize All Panes", menuPath: ["Pane"],
                   binding: KeyBinding("=", [.command, .option]),
                   isEnabled: { $0.tree.paneCount > 1 }) { $0.equalizeAll() },
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

    var body: some Commands {
        CommandMenu("Pane") {
            ForEach(PaneCommands.splits) { item($0) }
            Divider()
            ForEach(PaneCommands.others) { item($0) }
            Divider()
            Menu("Focus") {
                ForEach(PaneCommands.focusMoves) { item($0) }
                Divider()
                ForEach(PaneCommands.numbered) { item($0) }
            }
            Menu("Resize") {
                ForEach(PaneCommands.resizes) { item($0) }
            }
            Menu("Folder") {
                ForEach(PaneCommands.folders) { item($0) }
            }
        }
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
