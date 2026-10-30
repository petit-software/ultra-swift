# Ultra

**A Mac terminal built for working with coding agents.**

Split a window into panes and make each one what the work needs: a shell, an agent, a file tree, an editor, a todo list, Git, ports, resources, a context list, a chat, or a browser. Every pane is a native view, and a shell keeps its process through every change to the layout.

**[Download the latest release](https://github.com/petit-software/ultra-swift/releases/latest)** · macOS 26 Tahoe, Apple Silicon. Updates arrive in the app.

## Features

- **Agents as panes.** Claude Code, Codex and Gemini open in a pane of the project, with the project's own instructions. Type `@` for a file or `/` for a command at the prompt and a picker opens at the caret.
- **Every agent on one canvas.** The Agents overview gathers every working agent from every project. A notification says when one is waiting on you, or has gone quiet.
- **Agents can ask the app.** Each project exposes a socket, named in the shell's environment, so an agent can open a file in an editor pane, show its dev server in a browser pane, or reveal a path in Finder.
- **A shell that survives the layout.** Split, resize, rearrange, close a sibling, quit and reopen: the process never notices. Scrollback comes back after a relaunch, marked off from the live session.
- **Keyboard first.** Every action is a menu item with a shortcut, and fires while a terminal owns the keyboard. ⌘K opens the command palette.
- **Per project, in the project.** The plan is `.ultra/todo.md`, a Markdown task list in the repo, edited losslessly. The context list, the agent list and the layout live with the project too.
- **Chat with a model.** A Chat pane talks to Apple's on-device model, Anthropic, OpenAI, or the Claude Code and Codex CLIs already on the machine.

## Building

```sh
swift build && swift test      # the suite runs headless
./scripts/build-app.sh         # produces Ultra.app
```

A build from source never offers to update itself: it has no feed URL, so it cannot replace your checkout with a download.

## Documentation

[`docs/`](docs/) holds the design: the [overview](docs/00-OVERVIEW.md), the [split engine](docs/01-SPLIT-ENGINE.md), the [design language](docs/02-DESIGN-LANGUAGE.md), the [tiles](docs/03-TILES.md) and the [roadmap](docs/04-ROADMAP.md).
