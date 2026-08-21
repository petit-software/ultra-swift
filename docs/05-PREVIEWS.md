# 05 — Xcode Previews

**Every pane, every tile, and the canvas itself must have a working `#Preview`.** Not a
nice-to-have: a pane you cannot preview is a pane you can only test by launching the app,
spawning a shell, and building a layout by hand. That is the slow loop this rule exists to kill.

Open `Package.swift` in Xcode — previews work for library targets directly, so no app target is
needed to iterate on a tile.

## The rule

| Type | Must preview |
|---|---|
| Every `Tile` | Empty, loading, error, and populated states |
| Every chrome view (headers, palette, HUD, settings) | Light + dark, at minimum |
| `SplitCanvasView` | Several fixture trees, at more than one size |
| Shell pane | Replayed output, **no PTY** (see below) |

A view without a `#Preview` fails review. `swift test` includes a check that every type
conforming to `Tile` is named in at least one preview file.

## Previewing the canvas — an AppKit view

`SplitCanvasView` is an `NSView`, so it previews through its representable with a fixture tree:

```swift
#Preview("Grid 2×2", traits: .fixedLayout(width: 900, height: 600)) {
    SplitCanvas(store: LayoutStore(tree: .fixture(.grid2x2), panes: .placeholders))
}

#Preview("3 across", traits: .fixedLayout(width: 900, height: 300)) {
    SplitCanvas(store: LayoutStore(tree: .fixture(.threeAcross), panes: .placeholders))
}

#Preview("Deep nest", traits: .fixedLayout(width: 700, height: 700)) {
    SplitCanvas(store: LayoutStore(tree: .fixture(.deepNest), panes: .placeholders))
}
```

`LayoutTree.fixture(_:)` lives in `UltraLayout` (not the test target) precisely so previews and
tests share the same named layouts. When a golden layout test fails, the same fixture name is
already on screen in Xcode.

## Previewing a shell pane without a PTY

A preview cannot spawn a process — and should not want to. SwiftTerm separates the headless
`Terminal` engine from `TerminalView`, so a preview feeds recorded bytes instead:

```swift
#Preview("Shell — agent running") {
    ShellPanePreview(replaying: .recorded("claude-session"))
}
```

`RecordedStream` is a `[UInt8]` fixture captured once from a real session and checked in under
`Fixtures/Streams/`. This gives deterministic previews of prompts, colored output, and TUI
frames, and it doubles as the corpus for terminal regression tests.

This is the payoff of depending on `Terminal` and `TerminalView` through our own thin protocol
(`00-OVERVIEW.md` risk table): the seam that lets us swap the renderer is the same seam that
makes shell panes previewable.

## Preview data

Use the `swiftui-previews` skill (`.claude/skills/`) for the state matrix, and `ui-prototyping`
when exploring a tile's visual direction.

Every tile ships a `PreviewData` enum in the same file:

```swift
extension PortsTile {
    enum PreviewData {
        static let empty: [PortRow] = []
        static let typical: [PortRow] = [ /* 3000 node, 5432 postgres, 8080 caddy */ ]
        static let crowded: [PortRow] = /* 40 rows, to catch layout breakage */
        static let error = TileError.commandFailed("lsof: not found")
    }
}
```

Fixtures are plain values with no I/O. A tile whose view cannot be constructed from plain values
has its data layer tangled into its view — fix the tile, not the preview.

## Preview hygiene

- **Name every preview.** `#Preview("Crowded")`, never a bare `#Preview`. The name is the
  selector in Xcode's canvas.
- **Use `.fixedLayout` traits** for the canvas and for tiles that must be checked at a size.
- **No network, no disk, no `Process`.** A preview that shells out to `git` or `lsof` will hang
  or crash the preview agent. Tiles take their data through a protocol; previews pass a fixture
  conformance.
- **Dark mode**: `.preferredColorScheme(.dark)` as a second preview, not a variant of the first,
  so both are visible side by side.
- Previews are `#if DEBUG`-free — `#Preview` is already stripped from release builds.
