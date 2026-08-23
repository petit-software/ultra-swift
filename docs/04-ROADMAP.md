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
> **Outstanding:** nothing on this list — Todo reorder-by-drag and occlusion pausing both landed.

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
> **Diffs — LANDED.** Clicking a changed file opens its diff in the pane. `git diff` and
> `git diff --cached` are separate sides, because a file can be staged AND modified and one
> button cannot mean two things; the picker only appears when a file genuinely has both.
> Rendered in the pane with word-level highlighting inside a changed line, which is the
> reason not to shell out to a pager.
>
> Three things the build settled:
>
> - **An untracked file has no diff at all** — git has never seen it — so it is compared
>   against `/dev/null`. Otherwise clicking a new file shows an empty pane, which reads as
>   the tile being broken.
> - **A genuinely blank context line arrives as an EMPTY string**, because git drops the
>   single leading space. Treating it as a header desynchronises every line number after it,
>   silently, which is the one thing line numbers must not do.
> - **Unequal runs of deletions and additions are not paired** for intra-line highlighting.
>   Pairing by position across runs of different length highlights unrelated text; and when
>   two lines share too little, no highlight at all, since marking the whole of both says
>   nothing the colour did not already say.
>
> Outstanding: hunk-level stage/unstage, which is where this stops being small.

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

**General — changes how the app works. LANDED.**

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
  window is occluded** — the battery item already flagged under M4. `TilePolling.tick()`
  checks occlusion AFTER the interval, not before: a tile that has just become visible
  should refresh promptly rather than sit out a wait it started while hidden.

Two things the build settled:

- **"Follow System" must not pin the window's appearance.** The theme is derived FROM the
  system appearance, so pinning it back is a loop that never notices the system changing.
  `Preferences.pinsWindowAppearance` is false in that mode and the window is left alone.
- **A NaN sentinel silently disabled every write.** The no-op guard compared the new value
  against the stored one, using `.nan` to mean "nothing stored yet" — and every comparison
  against NaN is false, so the guard rejected the write instead of allowing it. Nothing
  could be set at all. Each setter now passes its own current value. Caught by tests within
  a minute of writing them; it would have looked like the settings window simply not working.

Both settings stores read and write through an injectable `UserDefaults`, because two test
suites in different targets mutating the same keys in `.standard` is a real flake — it
failed once before the runs went green, which is precisely how that bug presents.

**Appearance — removed.**

Ten live sliders over the design tokens were built and then taken out. The values they
exposed are constants again, at exactly the numbers the sliders defaulted to, so the app
looks unchanged. The tab was not earning its surface area: the defaults were the answer,
and every knob was one more thing to explain, migrate and keep honest.

One change was kept from the exercise: **the top inset is zero.** The toolbar's content
layout rect already holds the panes off the window's top edge, so padding there reads as a
second gap under the toolbar. `LayoutMetrics.topPadding` is the single place that says so,
`contentRect` is the single definition of the padded canvas, and a test asserts the topmost
pane in every fixture sits flush.

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

## M9 — Tile chrome, and a file tree that can leave the project

Small surface, and three of the four are corrections rather than features. Grouped because
they are all about a tile's edges: what draws over content, what steals width from it, and
what happens when a pane points somewhere the project does not own.

- **The footer ramp does not draw over a scrolling list.** It works over static content and
  looks like nothing at all over a `ScrollView`, which is most tiles.
- **Hide scrollbars while a pointing device is connected.** With a mouse attached macOS
  defaults to showing scrollbars always, which puts a permanent gutter inside every tile.
  Panes here are narrow by design and the gutter is a hard vertical edge across the glass.
- **Centre the Todo composer's `+`.** It is aligned to the text baseline and should be
  centred on the row, like the checkbox on every task beneath it.
- **A File Tree pane can leave the project.** Open any folder, travel outside the root, and
  come back in one click — with the pane saying plainly that it is somewhere else, rather
  than looking identical to a pane that is at home.

Three things to settle before building, recorded because two of them are invisible until
they bite:

- **`safeAreaInset` is why the ramp is missing.** It floats the footer AND shrinks the scroll
  view's safe area, so the list stops exactly at the footer's top edge. Nothing passes
  underneath, so there is nothing for the ramp to fade and it renders against flat pane
  background. The content has to extend the full height with only its *content* inset, not
  its bounds.
- **Hiding scrollbars overrides a deliberate system setting.** "Always" in System Settings is
  a choice someone made, and it is next door to an accessibility preference. This belongs
  behind a default-on setting that says what it overrides, in the same spirit as the
  keep-awake pane in M8 — not a silent policy.
- **Leaving the project must not widen the agent channel.** M4c refuses every path outside
  the workspace root, symlinks included, and refuses rather than clamps so a traversal
  attempt stays visible. A File Tree that can wander is a UI affordance only: opening a file
  from outside the root in the Editor must not become a path the socket will then accept.
  The two scopes are separate on purpose and this is the change most likely to quietly join
  them.

**Accept when** a list scrolled to its middle shows content fading out beneath the footer
rather than stopping at it; a tile shows no scrollbar gutter with a mouse attached; and a
File Tree pointed outside the project says so and returns home in one click — while the agent
channel accepts not one path it would have refused before.

## M10 — Agentic Sessions pane

One place that answers "what is running, and where is it?" Every agent session across the
workspace, its state, and one click to get to it — opening a shell for it if it is not on
screen already.

- List every active agent session, with what it is and whether it is working or waiting.
- Click a session to reveal the pane it lives in; if it has none, open one.
- Live state, driven from the signal that already exists rather than a view timer.

Most of the inputs are built: `ShellPaneFactory` tracks `runningAgentCount` and fires
`onAgentActivityChange`, `Registry.factories` is keyed by workspace so several tabs can be
enumerated at once, and `AgentDefinition.builtIns` plus `which` probing already say what an
agent IS. What is missing is a registry that names sessions rather than counting them.

**The thing to settle first: what "not open already" can mean.** Today a session's PTY dies
with its pane — "closing a pane is the only thing that kills its PTY" is a stated invariant
with a test behind it. So a session that is active but has no pane cannot exist, and the
pane's central verb has nothing to act on. Two readings, and they are different products:

- **Across tabs.** A session open in another window tab is invisible from this one. "Open"
  means reveal it there, or adopt it into this layout. Achievable now, changes no invariant,
  and is probably the case actually being asked for.
- **Truly detached.** A session that outlives its pane and can be re-attached later, the way
  tmux does it. That means breaking the pane-owns-the-PTY invariant, and with it the M2
  acceptance test that proves a shell survives layout operations because its surface is
  never rebuilt. Worth wanting, but it is an engine change, not a tile.

Build the first. The pane is the same either way; only what it can reach changes.

**Do NOT give shell panes their own tabs.** A pane with a tab strip is a second answer to
"which session am I looking at", competing with splits and with the window tabs from M3 —
three mechanisms for one question. This pane is the index; the layout is the workspace. If
the problem is screen space for parked agents, that is an argument for this list, not for
tabs inside a pane.

**Accept when** an agent started in one tab shows in the Sessions pane of another with live
state, clicking it puts the user in front of that session, and a session already on screen is
revealed rather than duplicated.

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
