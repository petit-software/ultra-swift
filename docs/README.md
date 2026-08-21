# Ultra (Swift) — Plan

A native macOS agentic terminal: a canvas of splittable panes, each holding a live shell or a
project-context tile.

Read in order:

| Doc | What it covers |
|---|---|
| [`00-OVERVIEW.md`](00-OVERVIEW.md) | Product, stack decisions, module layout, build order |
| [`01-SPLIT-ENGINE.md`](01-SPLIT-ENGINE.md) | **The window management and split engine.** Model, layout math, rendering, focus, resize, undo, persistence, accessibility, tests |
| [`02-DESIGN-LANGUAGE.md`](02-DESIGN-LANGUAGE.md) | Liquid Glass rules, materials, tokens, motion, accessibility |
| [`03-TILES.md`](03-TILES.md) | Shell, Todo, Resources, Git worktree, Context, Ports |
| [`04-ROADMAP.md`](04-ROADMAP.md) | Milestones with acceptance criteria, and risks |
| [`05-PREVIEWS.md`](05-PREVIEWS.md) | Xcode preview requirements for every pane and tile |

## The five ideas the plan rests on

1. **A pane's process outlives every layout change.** No split, resize, close, tab switch, or
   window restore may tear down a PTY. This is why AppKit owns pane frames rather than SwiftUI.
2. **The layout engine is pure and headless.** Tree and layout math have no AppKit dependency,
   so they are property-tested exhaustively with `swift test` and no window server.
3. **Glass is chrome, never content.** Terminal text sits on an opaque background; the frosted
   material is the space *between* panes.
4. **Keyboard-first, not keyboard-accessible.** Every action has a key path and a menu item, and
   fires even while a terminal owns the keyboard. The pointer is the fallback.
5. **Every pane previews.** A pane you cannot open in an Xcode canvas is a pane you can only test
   by launching the app and building a layout by hand.

## Skills installed for this project

`.claude/skills/` holds a curated subset of
[rshankras/claude-code-apple-skills](https://github.com/rshankras/claude-code-apple-skills) (MIT):
`liquid-glass`, `appkit-swiftui-bridge`, `ui-review-tahoe`, `macos-tahoe-apis`,
`macos-capabilities`, `macos-architecture-patterns`, `macos-coding-best-practices`,
`swift-concurrency-updates`, `concurrency-patterns`, `swift-memory`, `swiftui-layout`,
`swiftui-data-flow`, `swiftui-toolbars`, `swiftui-debugging`, `performance-profiling`,
`animation-patterns`, `sf-symbols`, `swiftui-previews`, `ui-prototyping`,
`accessibility-generator`, `accessibility-audit`, `snapshot-test-setup`, plus a locally authored
`keyboard-first` skill (no marketplace skill covers keyboard-first macOS *app* design, only its
accessibility slice).

User-scoped plugins: `swift-lsp` (SourceKit-LSP code intelligence) and `context7`
(up-to-date library docs).
