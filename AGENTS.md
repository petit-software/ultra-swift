<!-- ultra:start -->
## Working in Ultra

You are running in a pane of Ultra, a Mac terminal. The panes beside you show
project files you can read and edit directly.

### Plan in the todo list
- The plan lives in `.ultra/todo.md` — a GitHub task list. `##` headings are
  sections; nested items are subtasks.
- Read it before starting. Add tasks before the work, check them off as each finishes.
- Edit only task lines, with small targeted edits. Keep prose, notes and blank lines
  exactly as they are; the file is round-tripped losslessly and watched live.
- The user edits the same file as you work and may send a task line to you as a prompt.

### Context references
- `@path` in a prompt points at a file or folder the user dropped into the Context
  pane. Read it; it is a reference, not a command.
- Do not edit `.ultra/context.json` by hand. It holds bookmarks, not content.

### Chats
- `.ultra/chats/` holds the user's conversations with a model in a Chat pane.
  Read them for earlier decisions if useful. Never modify or delete them.

### Git, servers, processes
- Work in the current worktree. Do not switch branches, stash, or reset under the
  user. Commit only when asked.
- Start dev servers in the foreground of this shell rather than daemonising them,
  so they show up in the Ports pane with this pane as their owner.

### Committed and local
- `.ultra/todo.md` is committed: it is the project's plan.
- `.ultra/context.json` and `.ultra/chats/` are ignored: bookmarks are per machine
  and chats are personal.
<!-- ultra:end -->

## Project notes

- Build and test: `swift build && swift test`. The suite runs headless; no window server.
- `./scripts/build-app.sh` produces `Ultra.app`.
- Swift 6 with strict concurrency, macOS 26 only. Dependency direction between SPM targets
  is strictly downward: `UltraLayout` imports nothing of ours and nothing imports `Ultra`.
- Read `docs/00-OVERVIEW.md` first. The non-negotiable properties there (a PTY survives every
  layout change, the layout engine is pure, keyboard first) decide most design questions.
- Every user-facing action is a menu item with a key path before it is anything else. See
  the `keyboard-first` skill in `.claude/skills/`.
- Every pane and tile has a working `#Preview`.
