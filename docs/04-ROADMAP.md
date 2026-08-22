# 04 — Roadmap

Every milestone is independently shippable and demoable. Acceptance criteria are the exit test,
not a wish list.

---

## M0 — Foundations

Scaffolding only. No features.

- SPM package with the seven targets from `00-OVERVIEW.md`; thin Xcode app target depends on it.
- `swift build` and `swift test` run headless (no window server) and are green.
- App launches to an empty window: transparent titlebar, `.unifiedCompact` toolbar,
  `NSVisualEffectView(.underWindowBackground)` canvas.
- `UltraDesign`: semantic tokens, spacing scale, glass modifiers, SF Symbols catalogue.
- `UltraLayout.fixture(_:)` named layout trees, shared by previews and golden tests.
- Command registry + `CommandMenu` wiring, so every action is a menu item from day one.
- CI: build + test on every push.

**Accept when** the app launches, looks like a macOS 26 window with nothing in it,
`swift test` passes with zero targets importing AppKit that shouldn't, and opening
`Package.swift` in Xcode renders every `#Preview` in the package.

## M1 — Split engine ← *the milestone that matters*

> **Status: feature-complete bar accessibility.** Model, operations, layout, canvas,
> dividers, focus, zoom, equalize, undo, command registry, menus, palette, pane-header
> controls, the window bar, persistence/restore, and drag-to-rearrange with drop zones are
> built and green at **82 tests** (10,000 random operations; surfaces proven to build
> exactly once across 100 random layout operations; layouts proven to reopen with identical
> frames). Verified running: splits via menus and header buttons, divider drag via synthetic
> mouse events. **Outstanding:** the VoiceOver walkthrough, and dropping on the window's
> outer edges to split the root.

Full spec: `01-SPLIT-ENGINE.md`. Built and shipped with **placeholder colored panes**.

- Model, invariants, `normalize()`, property tests.
- `split` / `close` / `resize` / `equalize` / `zoom` / `swap` / `move`.
- Pure `layout()` with pixel snapping; golden tests at scale 1, 2, 3.
- `SplitCanvasView` + `PaneSurfaceStore`; surfaces never rebuilt on layout change.
- Divider drag: clamping, cursor rects, `⌥` push mode, `Esc` cancel, double-click equalize.
- Spatial focus navigation with directional memory; `⌘1`–`⌘9`.
- Undo (one entry per drag), persistence, restore with no visible reflow, schema versioning.
- Drag-to-rearrange with five drop zones.
- Accessibility: `splitGroup` / `splitter` roles, VoiceOver resize, full keyboard operation.

- Named `#Preview`s of the canvas over every fixture tree, at multiple sizes, light and dark.
- Every command declared in the registry with a `menuPath`; palette (`⇧⌘P`) lists them all.

**Accept when** a 6-pane layout can be built, resized, rearranged, zoomed, closed, undone,
quit, and relaunched pixel-identical — entirely from the keyboard, and again entirely with
VoiceOver. Property tests pass over 10k random operation sequences. Every canvas fixture
renders in the Xcode canvas.

## M2 — Shell tile

> **Status: core landed.** Real PTYs, splits, focus routing, theming, coalesced resize, and
> the agent launcher are built and green at **105 tests**, including live-process tests that
> assert a shell keeps its pid across 100 random layout operations. **Outstanding:**
> scrollback persistence, a font-settings surface, and the Metal renderer opt-in.
>
> One structural note: `LocalProcessTerminalView` is deliberately NOT used. Its `sizeChanged`
> is `public` rather than `open`, so its resize-immediately policy cannot be overridden from
> outside the module. `ShellTerminalView` owns a `LocalProcess` directly instead — about 60
> lines — which is what makes the coalescing below possible, and is the same seam that keeps
> a custom renderer reachable later.

- SwiftTerm integrated; `zsh -l` in a pane; Metal renderer on.
- PTY resize coalescing (33ms during drag, authoritative 50ms after commit).
- Terminal themes (light + dark defaults), font settings, selection, copy/paste, URL clicking.
- Scrollback persisted and restored as marked inert text.

- Shell pane previewable from a recorded byte stream, with no PTY (`05-PREVIEWS.md`).

**Accept when** a shell running `vim` survives 100 random layout operations with the same pid,
no visible redraw stutter while dragging a divider, and correct final rows/cols every time.
This is the executable form of the product's core promise — automate it and keep it in CI.

## M3 — Projects, tabs, sessions

> **Status: tabs landed.** Native macOS window tabs (⌘T), each tab owning its own
> `LayoutStore` so panes never leak between them, with the Pane menu resolving the focused
> tab through `@FocusedValue`. **Outstanding:** the project switcher, recent projects, and
> per-project window-frame restore.

- Project = directory + config. Session = pane + PTY + optional agent CLI.
- In-window tab strip; per-project layout saved and restored.
- Project switcher; recent projects; window frame restore per project.
- Agent registry with `which` probing; "new agent session" launcher.

**Accept when** switching between three projects restores each layout exactly, and no PTY is
killed by a tab switch.

## M4 — Todo, Ports, Resources

> **Status: all three landed**, plus a **file tree** tile that was not originally on this
> list. Todo round-trips markdown byte-for-byte (a toggle changes exactly one byte on disk,
> asserted by test, plus a 200-case property test over arbitrary markdown); Ports attributes
> listeners to this workspace's shells; Resources attributes by process ancestry.
> **Outstanding:** Todo reorder-by-drag, and pausing Resources on window occlusion.

- File tree: lazily-expanded project tree; click a file to send its quoted path to the shell.
- Todo: lossless markdown round-trip, file watching, conflict handling, send-to-shell.
- Ports: `lsof` polling, pane attribution, open/copy/kill.
- Resources: `ps` polling with ppid attribution, sparklines, occlusion-paused.

**Accept when** editing `.ultra/todo.md` in an external editor updates the tile within a second
and toggling a checkbox in the tile leaves surrounding prose byte-identical.

## M5 — Git worktree tile

> **Status: landed.** Branch, upstream divergence, worktrees, per-file index/worktree state,
> stage/unstage/discard, and in-flight rebase/merge detection — parsed from
> `--porcelain=v2`, verified in test against a real repository. **Outstanding:** creating a
> worktree from the tile, and opening a diff.

- Worktree list, branch, ahead/behind, status v2, per-file changes.
- Create worktree, point a pane at one, stage/unstage/discard, open diff.
- FSEvents-driven refresh.

**Accept when** the tile's branch and status match `git status` in a shell pane at all times,
including during a rebase, and no destructive git operation happens without an explicit click.

## M6 — Context tile

> **Status: landed.** Drop targets, bookmark-backed persistence (a file renamed between
> launches still resolves — asserted by test), token estimates, pin/unpin, and `@path`
> injection. **Outstanding:** dropping from other panes rather than only Finder.

- Drop files, folders, links from anywhere; security-scoped bookmarks.
- Token estimates; pin/unpin; per-project persistence.
- Send-to-shell injecting `@path` refs without submitting.

**Accept when** a folder dropped from Finder, the app quit and relaunched, still resolves and
can be sent into a fresh shell.

## M7 — Agent integration

- Per-pane agent activity state from the foreground process.
- Dock badge and menu-bar indicator driven from the app layer (not a view timer — the same
  throttling problem the Electron app solved by moving this to the main process).
- Notifications on long-running agent completion, opt-in.

## M8 — Polish and release

> **Status: started.** A Settings window (⌘,) exists with General and About, and General
> carries the keep-awake setting below. The rest of the list is untouched.

- **Keep the Mac awake while an agent is running.** An agent CLI runs for many minutes with
  nobody touching the keyboard, so the machine hits its idle timeout, sleeps the display and
  locks — and the user returns to a password prompt with no idea whether the work finished.
  A `ProcessInfo` activity is held for exactly as long as an agent pane is running, across
  every tab, and released the moment the last one exits. Tied to the work's lifetime on
  purpose: an assertion that outlives what it was protecting is how a laptop ends up flat.
  Plain interactive shells sitting at a prompt do not count as work. Cannot override a lock
  the user triggers, a closed lid, or an MDM policy — and the settings pane says so.
### Settings — the near-term list

Everything here is already a constant in the code; a setting is a binding plus a re-apply.
`Token` values are `static let` read from many call sites, so making them adjustable means
turning them into computed properties over `UserDefaults` with today's constants as the
defaults — about twenty lines, and no call site changes.

**General — changes how the app works.**

- **Terminal font size.** `ShellTerminalView.init(font:)` already takes one and nothing ever
  sets it. The resize path it needs — coalescing and `SIGWINCH` — is already built. Probably
  the single most-wanted setting in any terminal.
- **Theme: dark / light / follow system.** `TerminalTheme.isDark` exists and `WindowChrome`
  already pins the whole window's appearance to it; it is hardcoded `.dark` today.
- **Terminal background opacity.** `TerminalTheme.backgroundOpacity` is 0, which is what
  makes a shell's surface the pane's glass. Raising it makes shells opaque — and it is the
  knob that decides whether a shell's header has anything behind it to blur.
- **Show dotfiles in the file tree.** Shown by default now; the default belongs here, since
  `FileTreeModel.showsHidden` is per-pane and resets each time a pane opens.
- **Poll intervals** for Ports, Resources and Git (2s, 2s, 3s), and **pause polling while the
  window is occluded** — the battery item already flagged under M4.

**Appearance — live sliders over existing tokens.**

`windowTintOpacity`, `headerBlurRadius`, `headerTintOpacity`, `paneRadius`, `gutter`,
`paneShadowRadius`/`paneShadowOpacity`, and `windowRadius` — the last with a hard floor at
`systemWindowRadius`, since going under it is what produces the doubled-corner glitch.

This tab pays for itself immediately: tuning the header blur by shipping a guess and asking
whether it looks right is a slow way to find a number the user could just drag to.

**Later, and not one-liners.**

- Agent registry: add and remove agent commands. The model exists; only the UI is missing.
- Default pane kind for a new split.
- A Reduce Transparency override, to preview the opaque appearance without changing System
  Settings.
- Keymap editor with conflict detection against the shell's own bindings.
- Full accessibility audit against `02-DESIGN-LANGUAGE.md`, including Reduce Transparency as a
  first-class appearance.
- Performance pass with Instruments: divider drag holds display rate with 8 live shells;
  idle CPU near zero with the window occluded.
- Developer ID signing, hardened runtime, notarization, stapling, DMG, auto-update feed.

---

## Risks, and what we do about them

| Risk | Mitigation |
|---|---|
| SwiftTerm rendering or VT edge cases become the bottleneck | Its headless `Terminal` engine is separable — keep it, write a custom Metal renderer. Do not restart. Prove the boundary in M2 by depending on `Terminal` and `TerminalView` through our own thin protocol. |
| SwiftUI recreating a pane surface and killing a PTY | Structurally prevented: AppKit owns the frames and `PaneSurfaceStore` owns the views. The M2 acceptance test enforces it in CI. |
| `SIGWINCH` storms during drag | Coalescing rules in `01-SPLIT-ENGINE.md` § 6, with the "only if the character grid changed" guard. |
| Layout math drifting into the view layer | `UltraLayout` must not import AppKit. Enforce with a CI check on its import graph, not with discipline. |
| Glass hurting terminal legibility or frame rate | Settled by policy in `02-DESIGN-LANGUAGE.md`: terminal content is opaque. Revisit only with measurements. |
| Not sandboxed → no Mac App Store | Accepted and deliberate (`03-TILES.md`). Developer ID + notarization is the distribution path, as it already is for the Electron app. |
| A binding shadows a readline/tmux key and silently breaks the shell | The reserved-terminal-key table ships as data; the keymap editor validates against it and CI checks default bindings. See the `keyboard-first` skill. |
| Previews rot because a tile grows an I/O dependency | Tiles take data through a protocol; a build-time test asserts every `Tile` conformer appears in a preview. |
| Scope creep into building an agent loop | Out of scope. Ultra runs agent CLIs in PTYs. A native SDK loop, if ever wanted, is a new tile kind and touches no engine code. |
