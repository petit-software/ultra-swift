import SwiftUI
import UltraCanvas
import UltraLayout

/// One source of truth for every user-facing action.
///
/// The main menu, the command palette, the keymap editor, and the shortcuts window all
/// read from this. They are never written by hand three times. See the `keyboard-first`
/// skill in .claude/skills/.
struct AppCommand: Identifiable {
    /// Stable forever — it is the key in the user's saved keymap, so renaming it silently
    /// drops their binding.
    let id: String
    let title: String
    let menuPath: [String]
    let defaultBinding: KeyBinding?
    let isEnabled: @MainActor (LayoutStore) -> Bool
    let run: @MainActor (LayoutStore) -> Void

    init(id: String,
         title: String,
         menuPath: [String],
         binding: KeyBinding? = nil,
         isEnabled: @escaping @MainActor (LayoutStore) -> Bool = { _ in true },
         run: @escaping @MainActor (LayoutStore) -> Void) {
        self.id = id
        self.title = title
        self.menuPath = menuPath
        self.defaultBinding = binding
        self.isEnabled = isEnabled
        self.run = run
    }
}

struct KeyBinding: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Human-readable, for the palette and tooltips: bindings the user cannot see
    /// are bindings the user does not have.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .return: text += "↩"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

/// Keys a terminal legitimately owns. A binding that shadows one of these breaks the
/// user's shell silently, and they blame the shell.
///
/// Ships as data, not as prose in a doc, so the keymap editor can validate against it.
enum ReservedTerminalKeys {
    /// readline / emacs editing, tmux's default prefix, and shell job control.
    static let controlKeys: Set<Character> = [
        "a", "b", "c", "d", "e", "f", "g", "h", "k", "l", "n", "p", "r", "t", "u", "w", "y", "z",
    ]

    /// True if this binding would be swallowed by, or would steal from, a terminal.
    static func conflicts(_ binding: KeyBinding) -> Bool {
        let mods = binding.modifiers
        // Anything without ⌘ is fair game for the shell.
        guard mods.contains(.command) else {
            if mods == .control, case let character = binding.key.character {
                return controlKeys.contains(Character(character.lowercased()))
            }
            // ⌥ + arrows is word-jump in readline.
            if mods == .option,
               [KeyEquivalent.leftArrow.character, KeyEquivalent.rightArrow.character]
                .contains(binding.key.character) {
                return true
            }
            return mods.isEmpty
        }
        return false
    }
}
