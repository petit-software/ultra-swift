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

- Project = directory + config. Session = pane + PTY + optional agent CLI.
- In-window tab strip; per-project layout saved and restored.
- Project switcher; recent projects; window frame restore per project.
- Agent registry with `which` probing; "new agent session" launcher.

**Accept when** switching between three projects restores each layout exactly, and no PTY is
killed by a tab switch.

## M4 — Todo, Ports, Resources

- Todo: lossless markdown round-trip, file watching, conflict handling, send-to-shell.
- Ports: `lsof` polling, pane attribution, open/copy/kill.
- Resources: `ps` polling with ppid attribution, sparklines, occlusion-paused.

**Accept when** editing `.ultra/todo.md` in an external editor updates the tile within a second
and toggling a checkbox in the tile leaves surrounding prose byte-identical.

## M5 — Git worktree tile

- Worktree list, branch, ahead/behind, status v2, per-file changes.
- Create worktree, point a pane at one, stage/unstage/discard, open diff.
- FSEvents-driven refresh.

**Accept when** the tile's branch and status match `git status` in a shell pane at all times,
including during a rebase, and no destructive git operation happens without an explicit click.

## M6 — Context tile

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

- Settings: appearance, terminal themes, fonts, agent registry, keymap editor with conflict
  detection against the shell's own bindings.
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
