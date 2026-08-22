# 03 — Tiles

A pane holds a tile. The split engine gives it a rectangle and nothing else.

```swift
public protocol Tile: Identifiable, Sendable {
    static var kind: TileKind { get }
    var title: String { get }
    var subtitle: String? { get }          // e.g. branch name, cwd basename
    var headerActions: [TileAction] { get }
    func makeSurface(context: TileContext) -> NSView   // NSHostingView for SwiftUI tiles
    func encodeState() -> Data?
}
```

Every tile except Shell is a SwiftUI view in an `NSHostingView`. Shell is AppKit-native. Both go
into the same `PaneSurfaceStore` and are laid out by the same code.

`TileContext` carries the project root, the active worktree path, the focused shell's PTY handle
(for injection), and the workspace event bus.

---

## 1. Shell

The primary tile. A login shell, usually with an agent CLI running in it.

- **Engine**: SwiftTerm's `TerminalView` plus our own `LocalProcess`, as `ShellTerminalView`.
  Not `LocalProcessTerminalView`: it resizes the PTY the instant the grid changes and its
  `sizeChanged` is `public`, not `open`, so the policy cannot be overridden from outside the
  module. Owning the process is ~60 lines and buys the resize coalescing the product needs.
- **Padding**: SwiftTerm draws its grid flush to its bounds and has no content inset, so
  `ShellPaneContainer` paints the theme background across the pane and insets the grid inside
  it — the padding is part of the terminal, not a gap showing the pane behind it.
- **Keyboard**: the container refuses first-responder status; the canvas walks down to the
  first subview that accepts it. Handing a refusing wrapper to `makeFirstResponder` silently
  does nothing, which is exactly how a split leaves the caret in the pane you split away from.
- **Spawn**: `zsh -l` in the pane's cwd. An agent session runs `zsh -l -c "exec <command>"` so
  the CLI inherits the user's full PATH/env and gets a real TTY for its own TUI. This is exactly
  the Electron app's approach and it is the right one — Ultra is a harness, not an agent loop.
- **Agent registry**: `{ name, command }` entries, persisted, seeded with `claude` and `codex`.
  Availability probed with `which`; unavailable agents are shown disabled with a hint.
- **Resize**: driven by the coalescing rules in `01-SPLIT-ENGINE.md` § 6.
- **Scrollback**: kept in the live `Terminal` for the process lifetime. On quit, the last N lines
  are written to `~/Library/Application Support/Ultra/scrollback/<paneID>.txt` and restored as
  inert text above the new prompt, clearly marked as a previous session.
- **Header**: cwd basename, agent name, and an activity dot driven by the foreground process
  (`ps -t <tty> -o stat=,command=`) — the same technique as the Electron `process-name.ts`.
- **Injection API**: `inject(_ text: String, submit: Bool)` writes to the PTY master. `submit:
  false` leaves the text at the prompt so the user can add to it. Used by Context and Todo.

## 1b. File tree

The project's files, lazily expanded.

- **Reads one directory at a time** and caches it. A root with a 40,000-file `node_modules`
  costs nothing until someone opens that folder.
- **Flat row array, not a recursive `OutlineGroup`** — the list only ever holds what is
  visible, and expansion is testable without a view.
- **Collapsing forgets descendants' open state**, so reopening a folder does not explode back
  to a tree the user just closed.
- **Clicking a file sends its shell-quoted path** to the focused shell without submitting.
  A file tree that opened an editor would be a worse editor than the user's own; one that
  types a path for you is the thing a terminal actually lacks.

## 2. Todo — per-project markdown

Todos are files, not app state. They must be readable, diffable, committable, and editable by
the agent running in the next pane over.

- **Location**: `<project>/.ultra/todo.md`, created on first use. If `docs/TODO.md` or `TODO.md`
  already exists at the project root, offer to adopt it instead of creating a second list.
- **Format**: plain GitHub task lists. `##` headings are sections; `- [ ]` / `- [x]` are items.
  Nested items are subtasks.
- **Round-trip is lossless.** Parse into a model that retains every byte it does not own —
  prose, front matter, code fences, blank lines between blocks. Writing back rewrites only the
  task lines that changed. A user's notes between tasks survive a toggle.
- **External edits**: watch with `DispatchSource` on the file descriptor (plus a directory watch
  to survive atomic-replace saves). Reload on change. If the file changed on disk while a local
  edit was in flight (mtime + content hash mismatch), keep both: write the local version and
  surface a non-blocking "reloaded from disk — your edit is in the undo stack" notice.
- **Actions**: toggle, add, delete, reorder by drag, indent/outdent, and **Send to shell** —
  injects the task text into the focused shell without submitting.
- **Why markdown and not a database**: the agent in the adjacent pane can read and update it with
  no integration work at all. That is the entire point.

## 3. Resources

CPU and memory attributed to the panes that caused it.

- **Source**: `ps -axo pid=,ppid=,pcpu=,rss=,comm=`, parsed into a process table. Attribution
  walks the ppid chain from each pane's shell pid, so a `node` process started by an agent in
  pane 3 is charged to pane 3.
- **Poll**: 3s, and **paused when the window is occluded** (`NSWindow.occlusionState`) or the
  app is hidden. A monitoring tile that burns CPU while invisible is self-defeating.
- **Display**: per-pane row with title, CPU %, RSS, and a mini bar; a 60-sample sparkline;
  system totals (load, memory pressure via `vm_stat`/`host_statistics64`) in the footer.
- Sorting by CPU with a stable tie-break, so rows do not jitter between polls.

## 4. Git worktree

The project's dedicated worktree, its branch, and its changes.

- **Always shell out to the system `git`.** Never libgit2. The user's `~/.gitconfig`, aliases,
  hooks, credential helpers, `includeIf`, and signing config must all apply — an embedded library
  silently diverges from what the same command does in the shell next to it.
- **Reads**: `git worktree list --porcelain`, `git rev-parse --abbrev-ref HEAD`,
  `git status --porcelain=v2 --branch` (ahead/behind and per-file state in one call),
  `git diff --numstat` for line counts.
- **Display**: worktree path and branch in the header; ahead/behind chips; staged / unstaged /
  untracked sections with per-file rows and +/- counts.
- **Actions**: create a worktree for a branch (`git worktree add`), point a pane's cwd at a
  worktree, stage/unstage/discard (discard confirms, always), open a file's diff, copy branch name.
- **Refresh**: on FSEvents change under `.git/` plus a 5s floor, not a busy poll.
- **Destructive operations are explicit.** No auto-stash, no auto-commit, no implicit branch
  switching. The tile reports state and performs only what the user clicks.

## 5. Context

The drop target. Files, folders, and links that the agent should know about.

- **Accepts**: `NSPasteboard.PasteboardType.fileURL`, `.URL`, `.string`, and drags from Finder,
  the Files tile, a browser, or another app.
- **Persistence**: security-scoped bookmarks so a dropped folder outside the project is still
  readable after relaunch. Stale bookmarks are shown as such with a re-grant action.
- **Each chip** shows name, kind icon, size, and a token estimate (chars/4 heuristic to start;
  swap in a real tokenizer later without changing the UI).
- **Send to shell** — the reason the tile exists. Injects `@<path relative to project root>`
  references into the focused shell **without submitting**, so the user types their sentence
  around them. Multi-select joins with spaces. Absolute paths are used when the target is
  outside the project.
- **Also**: "Copy as prompt" (paths plus a short preamble), pin/unpin, remove, reveal in Finder.
- Stored per project alongside the layout.

## 6. Ports

Listening TCP ports, and which pane owns them.

- **Source**: `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` — field output, not columnar, because command
  names contain spaces. Unprivileged `lsof` reports the current user's processes, which is what
  we want.
- **Poll**: 3s, paused when occluded.
- **Columns**: port, process, pid, bind address. A port whose pid descends from a pane's shell is
  badged with that pane — "your dev server is in pane 2" is the useful fact.
- **Actions**: open `http://localhost:<port>`, copy the URL, reveal the owning pane, and kill
  (SIGTERM, then SIGKILL after 3s, with a confirmation).

---

## Sandboxing consequence

Spawning PTYs and shelling out to `lsof`, `ps`, and `git` are all incompatible with the App
Sandbox. Ultra ships **outside the Mac App Store**: Developer ID signed, hardened runtime,
notarized and stapled — the same pipeline documented in the Electron app's `AGENTS.md`. This is a
deliberate distribution decision, not an oversight, and it is why security-scoped bookmarks are
still used in the Context tile (they are about restoring user intent across launches, not the
sandbox).

## Adding a tile later

A new tile is: conform to `Tile`, register a `TileKind`, add a case to the pane-descriptor
decoder with a migration, add a menu item. **It touches no engine code.** If a tile ever needs a
change in `UltraLayout`, that is a signal the abstraction leaked — fix the boundary, not the tile.
