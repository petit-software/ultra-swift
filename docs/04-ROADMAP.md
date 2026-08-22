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

## M4b — Editor tile

> **Status: landed.** Open, edit, save with ⌘S, line numbers, external-change and conflict
> handling, binary refusal, and the open file persisted in the pane record. Reachable from a
> File Tree pane. **Outstanding:** nothing planned — see below.

Essential only, on purpose. Syntax highlighting, find and replace, multiple cursors,
autocomplete, split views and a tab bar are all deliberately absent: each one is a reason to
use the editor the user already has, and this tile exists so a one-line config fix does not
need a context switch. Full spec: `03-TILES.md` § 1c.

## M4c — Agent control channel ← *the one with real design risk*

> **Status: first slice landed.** A Unix socket per workspace, a closed two-verb protocol
> (`open`, `reveal`), workspace-scoped path resolution that REFUSES escapes including through
> symlinks, and `ULTRA_AGENT_SOCK` in every spawned shell's environment.
> **Outstanding:** `highlight` (needs selection support in the Editor) and `ask` (needs a
> form UI in the requesting pane).
>
> One thing the build taught us, recorded because it is invisible until it bites: the socket
> is NOT at `.ultra/agent.sock` as originally planned. `sockaddr_un.sun_path` is 104 bytes,
> and a checkout a few directories deep exceeds it — `bind` fails and the channel is silently
> dead for exactly the users with the most organised source trees. It lives in the temp
> directory under a short name instead, and the agent finds it in its environment.

Today the flow is one-way: Ultra injects text into an agent's prompt. The agent cannot ask
Ultra for anything. It should be able to say **"open this file"**, **"select these lines"**,
**"reveal this in the file tree"**, or **"here is a form, fill it in and send it back"** — so
a review turns into a click rather than a copy-paste of a path.

- **Transport.** A line-oriented protocol on a socket at `.ultra/agent.sock`, with the path in
  the pane's environment. NOT a terminal escape sequence: an escape sequence in scrollback
  replays when the buffer is redrawn, and any process that can write to the tty — including
  `cat`ing a hostile file — could drive the app. A socket is addressed by the process that
  was handed it.
- **Verbs, small and closed.** `open(path, line?, selection?)`, `reveal(path)`,
  `highlight(path, ranges)`, `ask(fields) -> values`. No eval, no arbitrary AppleScript, no
  "run this command" — the agent already has a shell for that, and a verb list that can grow
  without review is an injection surface.
- **Trust.** The socket is per-workspace, mode 0600, and only panes this app spawned get its
  path. Every verb is scoped to the workspace root: a path outside it is refused, not
  clamped, so a traversal attempt is visible rather than silently corrected.
- **`ask` needs a UI.** A small form in the pane that requested it, with the answer returned
  as a JSON line. This is the piece that makes "open something for me to fill" work, and the
  piece most likely to need iteration.

**Accept when** an agent can open a file at a line in the Editor pane, highlight a range the
user can see, and receive a filled-in form back — and when a `cat` of a file containing the
protocol's own bytes changes nothing.

## M4d — Editor: more than one file

The Editor pane holds exactly one file today. Multiple files need: a file list or tab strip,
per-file dirty state, "close" that asks about unsaved work, and reopening the whole set on
restore rather than just the front one. Deliberately after M4c, because the agent channel is
what makes opening files common enough for this to matter.

## M5 — Git worktree tile

> **Status: landed.** Branch, upstream divergence, worktrees, per-file index/worktree state,
> stage/unstage/discard, and in-flight rebase/merge detection — parsed from
> `--porcelain=v2`, verified in test against a real repository.
>
> **Outstanding — diffs.** Clicking a changed file should show its diff. `git diff` for
> unstaged and `git diff --cached` for staged, since a file can be both at once and one
> button cannot mean two things. Rendered in the pane, not shelled out to a pager: word-level
> highlighting within a changed line is most of the value, and a pager gives none of it.
> Hunk-level stage/unstage is the natural follow-on and is where this stops being small.
> Also outstanding: creating a worktree from the tile.

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
- **Where the Todo and Context lists live.** Choosable per project today, remembered in
  defaults; a global default (`.ultra/todo.md` vs `docs/TODO.md`) belongs here.
- **Poll intervals** for Ports, Resources and Git (2s, 2s, 3s), and **pause polling while the
  window is occluded** — the battery item already flagged under M4.

**Appearance — live sliders over existing tokens. LANDED.**

Ten knobs: `windowRadius`, `windowBorderWidth`, `windowTintOpacity`, `paneRadius`,
`paneShadowRadius`, `paneShadowOpacity`, `gutter`, `canvasPadding`, `headerBlurRadius`,
`headerTintOpacity`. `windowRadius` has a hard floor at `systemWindowRadius`, since going
under it is what produces the doubled-corner glitch.

Three things the build settled, worth keeping:

- **Clamping happens on the way out as well as in.** A value written by an older build, a
  synced defaults domain, or `defaults write` from a shell never passed through a slider.
  Clamping only on write leaves the floor unenforced for exactly the values nobody checked.
- **The store is the source of truth, not the layout pass.** Substituting the gutter while
  laying out looked equivalent and was not: `canSplit` and keyboard resize read
  `LayoutStore.metrics` too, so a split could be refused on a gutter the canvas was not
  using. `syncMetricsWithAppearance()` writes it in one place, and the initialiser applies
  it before the first layout so a window never opens on the defaults and jumps.
- **Layer state needs an explicit push.** Corner radii, shadows and the header's blur filter
  are set once when a view is built; only layout re-reads on its own. Without
  `refreshAppearance()` the slider moves, the number changes, and the window does not —
  a silent failure, so it is covered by tests that assert on the layer's applied radius
  rather than on the token.

The knobs are data (`Appearance.Knob`), so the tab is a `ForEach` rather than ten
hand-written sliders that drift out of step with the values behind them.

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
