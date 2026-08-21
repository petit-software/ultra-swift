# Ultra (Swift) — Overview & Architecture

A native macOS agentic terminal. Not a port of the Electron `ultra` — a rebuild that keeps
its product model (projects, sessions, tiles) and replaces the runtime with AppKit + SwiftUI.

## What it is

A window is a canvas of **panes**. Every pane holds a **tile**. A tile is either a live shell
(with an agent CLI running in it) or a piece of project context: todos, ports, resources,
git worktree, dropped files. The user splits the canvas top/down/left/right without limit,
and the layout is persisted per project.

The point of the product: an agent CLI needs context, and the surrounding tiles are how you
give it context without leaving the terminal. Dropping a folder into the Context tile and
hitting "send" should be faster than typing the path.

## Non-negotiable properties

1. **A pane's process outlives every layout change.** Resizing, splitting, closing a sibling,
   switching tabs, or restoring a window must never tear down a PTY. This constraint drives
   the rendering architecture (see `01-SPLIT-ENGINE.md` § Rendering).
2. **Dragging a divider is 120 Hz and does not flood the shell.** Frame updates are immediate;
   `SIGWINCH` is coalesced.
3. **Glass is chrome, never content.** Terminal text sits on an opaque background. See
   `02-DESIGN-LANGUAGE.md`.
4. **The layout engine is pure and headless.** No AppKit in the model or the layout math, so
   it is exhaustively unit-testable with `swift test` and no window server.
5. **Keyboard-first, not merely keyboard-accessible.** Every action has a menu item and a key
   path, and fires while a `TerminalView` owns the keyboard. See the `keyboard-first` skill in
   `.claude/skills/` — key routing around a terminal first responder is the hard part and it
   constrains where commands are declared.
6. **Every pane and tile has a working `#Preview`.** See `05-PREVIEWS.md`. This constrains tile
   design: a tile takes its data through a protocol so a preview can pass fixtures instead of
   shelling out.

## Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 6.3, strict concurrency | Toolchain on this machine; `@Observable` + actors |
| Deployment target | macOS 26.0 | Liquid Glass APIs (`glassEffect`, `NSGlassEffectView`) are 26+ |
| App shell | SwiftUI `App` scene, AppKit where it matters | SwiftUI for tiles/chrome, AppKit for the canvas |
| Split canvas | Custom `NSView` + manual `setFrame` | Property 1 & 2 above; SwiftUI cannot guarantee either |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Xterm/VT100 in Swift, `LocalProcessTerminalView` for PTY, optional Metal renderer, shipped in Secure Shellfish / La Terminal / CodeEdit |
| Build | SPM libraries + thin Xcode app target | `swift test` runs headless in CI; only the bundle needs Xcode |
| Persistence | Codable JSON, atomic writes | Layout trees and workspace state; todos are plain `.md` |
| Distribution | Developer ID, notarized, **not** sandboxed | `lsof`, `ps`, `git`, and PTY spawning are all incompatible with the App Sandbox |

### Why not write our own terminal emulator

VT sequence handling is a multi-year tail of edge cases (mouse modes, bracketed paste, OSC 8
hyperlinks, sixel, wide-char/ZWJ grapheme widths, alternate screen, scroll regions). SwiftTerm
already carries that, is Swift-native, and exposes `Terminal` (headless engine) separately from
`TerminalView` (AppKit). If its rendering ever becomes the bottleneck, the escape hatch is to
keep `Terminal` and write a custom Metal renderer against it — not to restart.

## Module layout (SPM targets)

```
UltraLayout    pure model + layout math. Depends on CoreGraphics only. 100% unit-tested.
UltraCanvas    AppKit. SplitCanvasView, dividers, PaneSurfaceStore, drag/drop, AX.
UltraTerminal  SwiftTerm wrapper, PTY lifecycle, resize coalescing, themes.
UltraDesign    design tokens, glass modifiers, SF Symbols catalogue.
UltraTiles     SwiftUI tiles: todo, ports, resources, git, context.
UltraCore      project/workspace model, persistence, system services (ps/lsof/git).
Ultra          the app target: scenes, menus, keymap, settings.
```

Dependency direction is strictly downward. `UltraLayout` imports nothing of ours; `UltraCanvas`
imports `UltraLayout`; nothing imports `Ultra`.

## Build order

Each milestone is shippable and demoable on its own.

| # | Milestone | Done when |
|---|---|---|
| **M0** | Foundations | SPM skeleton, app launches, window chrome + materials, design tokens |
| **M1** | **Split engine** | Splits/close/resize/focus/zoom/undo/persist — with *placeholder colored panes*, no terminal yet. Full test suite green. |
| M2 | Shell tile | SwiftTerm + PTY in a pane, survives every M1 operation, theming, scrollback |
| M3 | Projects & tabs | Project switching, per-project layout restore, session model |
| M4 | Todo / Ports / Resources tiles | Todos round-trip to `.md`; ports and resources poll live |
| M5 | Git worktree tile | Worktree list, branch, status, per-file changes |
| M6 | Context tile | Drop files/folders/links, send refs into the focused shell |
| M7 | Agent integration | Agent CLI registry, per-pane activity state, Dock/menu-bar indicator |
| M8 | Polish & release | Settings, themes, keymap editor, accessibility audit, notarized DMG |

**M1 is built and tested before a single terminal exists.** Placeholder panes are colored
rectangles with a label. If the engine is not perfect with dumb panes, no amount of terminal
work will rescue it — and debugging layout through a live PTY is miserable.

## Documents

- `01-SPLIT-ENGINE.md` — the window management and split engine. Start here.
- `02-DESIGN-LANGUAGE.md` — glass, materials, tokens, motion, accessibility.
- `03-TILES.md` — shell, todo, resources, git worktree, context, ports.
- `04-ROADMAP.md` — milestone breakdown with acceptance criteria.
- `05-PREVIEWS.md` — Xcode preview requirements for every pane and tile.

## Open questions

- **Tabs vs. windows.** M1 assumes one canvas per window with an in-window tab strip.
  Detaching a pane into its own window is deferred to post-M8.
- **Agent transcripts.** The Electron app has `transcripts.ts` / `chat-agent.ts`. This plan
  treats the agent as a CLI in a PTY only (the `ultra` app's own documented default). If a
  native SDK loop is wanted later it is an additional tile kind, not a change to the engine.
