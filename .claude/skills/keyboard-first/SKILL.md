---
name: keyboard-first
description: Keyboard-first interaction design for this macOS app. Every action reachable without a pointer, key routing around a terminal first responder, leader keys, command palette, focus rings, and the review checklist. Use when adding ANY user-facing action, control, menu item, or view.
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash]
---

# Keyboard-First

Ultra is a terminal. The user's hands are on the keys. **Any action that requires the pointer is
a bug**, not a missing enhancement.

This is stricter than accessibility compliance (see `accessibility-audit` and `ui-review-tahoe`
for that layer). Those ask "can it be operated without a mouse?". This asks "is the keyboard the
*primary* path, and is the pointer the fallback?"

## The three laws

1. **Every action has a key path.** Before a control ships, it has either a key equivalent or a
   command-palette entry. No exceptions, including destructive and rarely-used actions.
2. **Every action is a menu item first.** The `NSMenu` is the registry. Key equivalents are
   declared on menu items, never on views. This is not style — see § Key routing.
3. **Focus is always visible and always somewhere.** There is no state in which the user cannot
   tell what a keystroke will act on.

## Key routing — the hard problem

A `TerminalView` is a first responder that legitimately consumes nearly every keystroke,
including plain letters, arrows, `⌃`-combos, and often `⌥`-combos. A naive `.onKeyPress` or a
custom `NSView.keyDown` in the responder chain will never see them.

**The main menu wins before the responder chain.** `NSApplication.sendEvent(_:)` offers a key
event to `NSApp.mainMenu.performKeyEquivalent(with:)` *before* the event reaches the key window's
first responder. So an app command declared as a menu item with a key equivalent fires even while
a full-screen TUI has the keyboard.

```
NSApp.sendEvent
  → mainMenu.performKeyEquivalent          ← app commands live HERE
  → keyWindow.sendEvent
      → window.performKeyEquivalent        ← buttons' keyEquivalent, default/cancel
      → firstResponder.keyDown             ← TerminalView eats everything from here down
```

Consequences, and they are not negotiable:

- **App commands are menu items.** SwiftUI: `CommandMenu` / `CommandGroup` in the `Scene`, not
  `.keyboardShortcut` on a view buried in a pane. A `.keyboardShortcut` on a view only works if
  that view is in the responder chain — which, next to a terminal, it usually is not.
- **Hidden commands still get menu items**, marked `isAlternate` or placed in a Debug/Advanced
  menu, rather than being wired up off-menu.
- **Never bind a plain key or a bare `⌃`-combo** as an app command. `⌃A`, `⌃E`, `⌃C`, `⌃D`,
  `⌃R`, `⌃W`, `⌃U`, `⌃K` are readline; `⌥←/→` is word-jump; `⌃B` is tmux's default prefix.
  Stealing them breaks the shell silently and the user blames the shell.
- Reserve `⌘`, `⇧⌘`, `⌥⌘`, `⌃⌘` for app commands. `⌃⌘` is the safest of the four.
- The keymap editor **must** validate a proposed binding against the reserved-terminal table and
  refuse or warn. Ship that table as data, not as prose in a doc.

### Escape hatches

- **Leader key** for anything that would otherwise need a bad binding: a prefix (default `⌃⌘Space`)
  puts the app in a one-shot mode where the *next* keystroke is an app command and the terminal
  sees nothing. Show a HUD listing the available follow-ups. `Esc` cancels. Never a sticky mode.
- **Command palette** (`⌘K`) is the universal fallback: every registered command is fuzzy
  searchable by title, with its key equivalent shown beside it so the palette teaches bindings.
  A command with no key equivalent is still fully reachable here.
- **Pass-through**: `⌃⌘V` sends the *next* keystroke verbatim to the terminal, so a user who
  genuinely needs `⌘K` in their TUI can get it.

## The command registry

One source of truth. Menu items, the palette, the keymap editor, and the help search all read
from it — they are never written by hand three times.

```swift
struct Command: Identifiable, Sendable {
    let id: CommandID              // stable, e.g. "pane.split.right" — persisted in keymaps
    let title: String              // "Split Right" — menu title and palette label
    let subtitle: String?          // context, e.g. "Focused pane"
    let menuPath: [String]         // ["Pane", "Split"] — where it lives in the main menu
    let defaultBinding: KeyBinding?
    let isEnabled: @MainActor () -> Bool
    let run: @MainActor () -> Void
}
```

Rules:

- `CommandID` is stable forever. It is the key in the user's saved keymap; renaming it silently
  drops their binding.
- `isEnabled` drives `validateMenuItem` **and** whether the palette shows the row as dimmed.
  A command that cannot run says so rather than disappearing — a disappearing command is
  unlearnable.
- Adding a command without a `menuPath` fails a build-time test. There is no off-menu command.

## Focus

- **`focusedPane` is app state, not view state.** It lives in the store, drives
  `window.makeFirstResponder`, and survives layout changes. Never let AppKit's focus and the
  model's focus disagree — reconcile in one direction only (model → AppKit).
- **A visible focus ring on every focusable chrome control**, using the system focus ring
  (`NSFocusRingType.default` / SwiftUI's default) — never a custom outline that ignores
  Increase Contrast.
- **The focused pane is unmistakable** without relying on the focus ring alone: an accent border
  and a subtle brightness difference on unfocused pane headers. Not color alone.
- **Full Keyboard Access** (System Settings → Keyboard) must let `Tab` reach every control.
  Test with it ON — it is off by default and it is how a large share of keyboard users work.
- `Tab` order follows visual order. Set `nextKeyView` explicitly in AppKit containers rather
  than trusting the default geometric guess.

## Discoverability

Keyboard-first fails if bindings are secret.

- Every menu item shows its key equivalent — that is what the menu is *for*.
- The palette shows bindings next to titles.
- Tooltips on chrome controls append the shortcut: `"Split Right (⌘D)"`.
- A Keyboard Shortcuts window (`⌘/`) lists every command by group, searchable, and is generated
  from the registry.
- The leader-key HUD lists follow-ups after a short delay.

## Review checklist

Run against every PR that adds or changes a user-facing action.

- [ ] Every new action has a `Command` with a stable `id` and a `menuPath`.
- [ ] Its key equivalent uses `⌘`/`⇧⌘`/`⌥⌘`/`⌃⌘` only, and is checked against the reserved
      terminal-key table.
- [ ] It fires while a `TerminalView` is first responder (test with `vim` open in the pane).
- [ ] It appears in the command palette with its binding shown.
- [ ] `isEnabled` is implemented; the menu item dims rather than vanishing.
- [ ] Any new pointer affordance (drag handle, hover button, context menu) has a keyboard
      equivalent that does the same thing.
- [ ] `Tab` reaches every new control with Full Keyboard Access ON, in visual order.
- [ ] The focus ring is visible on every new control and survives Increase Contrast.
- [ ] `Esc` cancels any new modal, drag, or transient mode.
- [ ] No new binding shadows a readline, tmux, or terminal editing key.

## Anti-patterns

| Don't | Do |
|---|---|
| `.keyboardShortcut()` on a view inside a pane | `CommandMenu` / `NSMenuItem` at the app level |
| Hover-only buttons in a tile header | Also reachable via the pane's context command group |
| Drag-only reordering | `⌥↑/↓` to move the selected row |
| A destructive action with no confirm and no undo | Confirm, or register an undo — reachable by `⌘Z` |
| Binding `⌃W` because "it means close" | It is readline's delete-word. Use `⌘W`. |
| A command reachable only from a context menu | Register it; context menus are a *view* of the registry |
