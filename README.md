# Ultra

A Mac-native agentic terminal. Split a window into panes and make each one what you need — a
shell, a git worktree, a todo list, a file tree, an editor, a context list, ports, or system
resources. A pane changes what it is from its own name.

**[Download Ultra 0.1.1](https://github.com/petit-software/ultra-swift/releases/latest)** —
requires macOS 26 (Tahoe) on Apple Silicon. Updates arrive through Sparkle.

## What it does differently

- **A shell keeps its process through every layout change.** Split, resize, rearrange, close a
  sibling, quit and reopen — the PTY never notices. AppKit owns pane frames for this reason.
- **Keyboard-first, not keyboard-accessible.** Every action has a key path and a menu item, and
  fires while a terminal owns the keyboard.
- **Per-project, in the project.** Todo lists are markdown files in your repo, edited losslessly —
  toggling a checkbox changes one byte.
- **Scrollback survives a relaunch,** marked off from the live session so you can tell what did
  and did not run in this shell.

## Building

```sh
swift build && swift test      # 359 tests, no window server needed
./scripts/build-app.sh         # produces Ultra.app
```

A build from source never offers to update itself — it has no feed URL, so it cannot replace
your checkout with a download.

## Documentation

[`docs/`](docs/) holds the design and the plan: the [split
engine](docs/01-SPLIT-ENGINE.md), the [design language](docs/02-DESIGN-LANGUAGE.md), the
[tiles](docs/03-TILES.md), and the [roadmap](docs/04-ROADMAP.md) with what is built and what is
not.

Early software. The split engine and shell tile carry most of the test coverage; the tiles rather
less.
