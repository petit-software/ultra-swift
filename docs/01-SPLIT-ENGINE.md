# 01 — Window Management & Split Engine

The engine is the product. Everything else is a tile that gets a rectangle from it.

Three layers, strictly separated:

```
LayoutTree      value type, Codable, pure. Knows nothing about pixels.
    ↓  layout(tree, in: rect) -> LayoutResult          pure function, CoreGraphics only
SplitCanvasView AppKit NSView. Applies frames. Owns divider hit-testing, drag, AX.
    ↓  PaneSurfaceStore: [PaneID: NSView]              retained, never rebuilt
Tile content    SwiftTerm TerminalView, or NSHostingView<some View>
```

Layers 1 and 2 have no AppKit dependency and are covered by unit tests. Layer 3 is thin.

---

## 1. The model

```swift
public typealias PaneID = UUID
public typealias NodeID = UUID

public enum Axis: String, Codable, Sendable {
    case horizontal   // children laid out left → right
    case vertical     // children laid out top → bottom
}

public enum Edge: String, Codable, Sendable { case left, right, top, bottom
    var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }
    var insertsBefore: Bool { self == .left || self == .top }
}

public indirect enum LayoutNode: Codable, Equatable, Sendable, Identifiable {
    case leaf(Leaf)
    case container(Container)

    public var id: NodeID { switch self { case .leaf(let l): l.id; case .container(let c): c.id } }
}

public struct Leaf: Codable, Equatable, Sendable, Identifiable {
    public let id: NodeID
    public var paneID: PaneID
    /// The pane this one took its space from, so `close` can give it back. See § close.
    public var spaceFrom: PaneID?
}

public struct Container: Codable, Equatable, Sendable, Identifiable {
    public let id: NodeID
    public var axis: Axis
    public var children: [LayoutNode]   // count >= 2
    public var fractions: [Double]      // count == children.count, each > 0, sums to 1
}

public struct LayoutTree: Codable, Equatable, Sendable {
    public var root: LayoutNode
    public var focused: PaneID
    public var zoomed: PaneID?          // non-destructive maximize
}
```

**N-ary, not binary.** Three panes side by side are one container with three children, not a
binary tree nested two deep. This matters: with a binary tree, dragging the middle divider of a
3-across layout resizes a *subtree*, so one pane moves twice as fast as the other and the
behaviour depends on insertion order. With an n-ary container, every divider moves exactly two
neighbours. This is the tmux/Zed model and it is the reason the engine feels correct.

### Invariants

Enforced by `normalize()`, run after every mutation, asserted in debug builds and property-tested:

1. Every `Container` has at least 2 children.
2. `fractions.count == children.count`; every fraction `> minFraction`; sum is 1 (±1e-9).
3. **No container has a direct child container of the same axis.** Same-axis children are
   flattened into the parent, with the child's fractions scaled by the slot it occupied.
4. Every `PaneID` appears exactly once, and exists in the pane store.
5. `focused` and `zoomed` reference live panes.

Invariant 3 is the one that keeps the tree shallow. Without it, `split right` three times
produces a right-leaning chain and every divider drag resizes a different amount of content.

---

## 2. Operations

All are pure `(LayoutTree) -> LayoutTree`, expressed as `mutating` methods on the value type,
returning `false` (or throwing) when the operation is impossible. No operation ever leaves the
tree in a non-normalized state.

### split

```swift
mutating func split(_ paneID: PaneID, edge: Edge, newPane: PaneID, ratio: Double = 0.5) -> Bool
```

- **Parent axis == `edge.axis`** → insert the new leaf as a sibling adjacent to the source.
  The new pane's fraction is taken **only from the source pane** (`f → f*(1-ratio)`, new gets
  `f*ratio`). Every other sibling keeps its exact size.
- **Otherwise** → replace the leaf in place with a new `Container(axis: edge.axis)` holding
  the original and the new leaf, ordered by `edge.insertsBefore`, fractions `[1-ratio, ratio]`.
- **Root is a leaf** → the root becomes that new container.
- Refuses if the resulting pane would be below `minPaneSize` in the current canvas — the split
  is rejected with a UI nudge rather than producing an unusable 20pt pane.

> The "take only from the source pane" rule is deliberate and is what most split engines get
> wrong. Re-equalizing all siblings on every split means the user's carefully sized 3-across
> layout is destroyed the moment they split a fourth pane off one of them.

### close

```swift
mutating func close(_ paneID: PaneID) -> Bool
```

1. Remove the leaf and give its fraction back to **the pane it was split from**, if that pane
   is still a sibling. A `Leaf` records this provenance (`spaceFrom`) when a split creates it.
   Splitting and immediately closing is therefore an exact inverse: change your mind and no
   other pane has moved. Without it, `split` takes space from one pane while `close` hands it
   back to all of them, and a 3-across layout drifts every time you try a fourth pane.
2. If there is no provenance — a restored pane, or one that was moved — distribute the fraction
   to the remaining siblings **proportionally** (not equally), which at least preserves their
   relative sizes.
3. If the container is left with one child, splice that child into the grandparent in the
   container's slot, inheriting its fraction.
4. `normalize()` — which may now flatten a same-axis nesting exposed by step 3.
5. Move focus per § 5 (nearest sibling in the direction the pane occupied, else MRU).
6. Refuses to close the last pane; the window closes instead.

`swap` and `move` clear provenance, because after them it would describe a relationship that
no longer exists.

### resize

```swift
mutating func resize(divider: DividerRef, by delta: CGFloat, containerSize: CGFloat,
                     mode: ResizeMode = .hardStop) -> CGFloat   // returns applied delta
```

A `DividerRef` is `(containerID, index)` — the boundary between children `index` and `index+1`.

- Converts `delta` (points) to a fraction delta using `containerSize`.
- Moves **only** the two adjacent children. `f[i] += d; f[i+1] -= d`. Sum is trivially preserved.
- Clamps so neither adjacent pane drops below `minPaneSize`. On hitting the clamp the divider
  **hard stops** — it does not start pushing the next divider along. Cascading feels like the
  layout is sliding out from under you.
- `mode: .push` (⌥-drag) opts into the cascade for users who want it, consuming slack from
  successive siblings until the container runs out.
- Returns the delta actually applied so the drag handler can keep the cursor glued to the divider.

### equalize / zoom / swap / move

```swift
mutating func equalize(container: NodeID)      // ⌘= or double-click a divider
mutating func equalizeAll()
mutating func toggleZoom(_ paneID: PaneID)     // sets tree.zoomed; the tree is untouched
mutating func swap(_ a: PaneID, _ b: PaneID)
mutating func move(_ paneID: PaneID, toEdgeOf target: PaneID, edge: Edge)  // close + split, atomically
```

`toggleZoom` is non-destructive — it sets a field the layout function reads. Un-zooming restores
the exact previous geometry because the geometry was never modified. (tmux's `resize-pane -Z`,
same idea.)

---

## 3. The layout function

```swift
public struct LayoutMetrics: Sendable {
    public var gutter: CGFloat = 6        // space between siblings
    public var padding: CGFloat = 8       // canvas inset
    public var minPaneSize = CGSize(width: 160, height: 80)
    public var dividerHitWidth: CGFloat = 8   // hit area
    public var dividerLineWidth: CGFloat = 1  // drawn hairline, centered in the gutter
    public var scale: CGFloat = 2.0       // backing store scale, for pixel snapping
}

public struct LayoutResult: Equatable, Sendable {
    public var frames: [PaneID: CGRect]
    public var dividers: [DividerFrame]
    public var hidden: Set<PaneID>        // non-empty only while zoomed
}

public struct DividerFrame: Equatable, Sendable {
    public let ref: DividerRef
    public let axis: Axis
    public let hitRect: CGRect
    public let lineRect: CGRect
    public let fraction: Double           // exposed as the AX splitter value
}

public func layout(_ tree: LayoutTree, in bounds: CGRect,
                   metrics: LayoutMetrics) -> LayoutResult
```

Pure, synchronous, allocation-light, and called on every live-resize frame.

### Pixel rules

These are not polish; they are the difference between crisp and shimmering.

1. **Subtract gutters first, then distribute.** `available = size - gutter * (n - 1)`.
   Distributing fractions over the full size and then insetting produces drift.
2. **Snap every edge to the backing store**: `round(x * scale) / scale`. Snap *edges*, not
   sizes, so adjacent panes always share an exact boundary and no 1px seam or overlap appears.
3. **Give the rounding remainder to the last child** so the children's edges sum exactly to the
   container's trailing edge. Never let the last pane be a pixel short.
4. **A 1pt hairline is drawn centered in a 6pt gutter with an 8pt hit area** — the hit area is
   allowed to exceed the gutter and overlap the panes by 1pt each side. Users aim at the visible
   line; they should not have to be precise.
5. **At a crossing, the nearest hairline wins.** A vertical and a horizontal divider necessarily
   overlap where they meet, so hit areas alone are ambiguous there. Resolving by distance to the
   drawn line is deterministic and matches what the user aimed at; taking the first match in
   array order means a grab at a junction picks an arbitrary divider. Parallel dividers must
   never overlap at all — that would be two grabs for one gesture, and it is asserted in tests.
6. Zoomed pane gets `bounds.insetBy(padding)` and every other pane goes into `hidden`.

### Cost

`layout` is O(nodes). For any realistic canvas (< 30 panes) it is microseconds. It is called
from `NSView.layout()` and from the drag handler; there is no caching layer and none is needed.
Do not add one before measuring.

---

## 4. Rendering — why AppKit owns the frames

**The rule from `00-OVERVIEW.md`: a pane's process outlives every layout change.**

A shell pane hosts a live PTY with scrollback. If the view backing it is deallocated and
recreated, the process is gone and the user's work with it. SwiftUI's `NSViewRepresentable`
gives no hard guarantee about coordinator/view lifetime across structural identity changes —
and a split *is* a structural identity change to the view tree. Betting the core promise of the
product on SwiftUI diffing heuristics is not a bet worth taking.

So the canvas is AppKit and owns frames directly:

```swift
final class SplitCanvasView: NSView {
    private let surfaces: PaneSurfaceStore          // PaneID -> NSView, retained
    private let dividerOverlay: DividerOverlayView  // hit-testing + cursor rects, drawn on top
    var tree: LayoutTree { didSet { reconcile(oldValue) } }

    override func layout() {
        let result = UltraLayout.layout(tree, in: bounds, metrics: metrics)
        for (paneID, frame) in result.frames {
            surfaces[paneID]?.frame = frame               // <- the whole rendering step
            surfaces[paneID]?.isHidden = false
        }
        for paneID in result.hidden { surfaces[paneID]?.isHidden = true }
        dividerOverlay.dividers = result.dividers
    }

    /// Subviews are added/removed ONLY here, and only for panes that genuinely
    /// appeared or disappeared. A resize or a sibling split touches nothing.
    private func reconcile(_ old: LayoutTree) { /* diff paneIDs, add/remove surfaces */ }
}
```

`PaneSurfaceStore` is the single owner of pane views. A surface is created once when a pane is
created and released once when the pane is closed. Tab switches hide the canvas, they do not
unmount surfaces.

What this buys, concretely:

- **Zero teardown risk.** Splitting a sibling is a `frame` assignment on existing views.
- **Drag resize at display rate.** No SwiftUI diff, no `@Observable` invalidation storm,
  no view-body re-evaluation — just `setFrame` on N views.
- **Exact control over PTY resize timing** (§ 6), which is impossible if a framework decides
  when views get laid out.

SwiftUI is still everywhere above and inside: the tree lives in an `@Observable LayoutStore`,
the whole canvas is wrapped by **one** `NSViewRepresentable` at the tab level, and non-terminal
tiles are `NSHostingView<TileView>` instances in the same surface store. Glass tiles and terminal
panes are laid out by identical code paths.

### Layer-backing

Every surface is layer-backed with `canDrawSubviewsIntoLayer = false` and
`layerContentsRedrawPolicy = .onSetNeedsDisplay`, so a frame change is a compositor transform,
not a redraw of terminal content.

---

## 5. Focus and spatial navigation

`tree.focused` drives `window.makeFirstResponder(surfaces[focused])`. Changing focus never
changes geometry.

**Directional focus (`⌘⌥←/→/↑/↓`) is spatial, not tree order.** Tree-order navigation in a
grid sends you somewhere unrelated and is the single most common complaint about split panes.

Algorithm, given the focused pane's frame `S` and direction `d`:

1. Candidates = panes whose frame lies strictly on the `d` side of `S` (e.g. for `.right`,
   `frame.minX >= S.maxX - ε`).
2. Prefer candidates whose projection on the perpendicular axis **overlaps** `S`. Among those,
   pick the smallest gap along `d`; break ties by largest overlap, then by most-recently-focused.
3. If none overlap, fall back to the candidate with the smallest Euclidean distance between
   frame centers.
4. If still none, do nothing (no wrap-around — wrapping in a spatial layout is disorienting).

**Directional memory.** Keep `lastEntry: [PaneID: [Edge: PaneID]]`. Moving right from A into B
records that going left from B should return to A, even if a different pane is geometrically
closer. This is what makes ←→←→ round-trip instead of drifting.

`⌘1`…`⌘9` focus panes by **visual order** (sorted by `minY` then `minX`), not tree order — the
number the user counts on screen is the number they press.

---

## 6. Live resize and PTY sizing

Two independent clocks. Conflating them is what makes terminals feel sluggish while dragging.

**Frames: every event.** `mouseDragged` → `resize(divider:by:)` on a **transient** copy of the
fractions held by the drag session, then `needsLayout = true`. The model is not written during
the drag. This keeps `@Observable` quiet, keeps undo clean (one entry per drag, § 8), and
avoids persistence churn.

**PTY size: coalesced.** Computing rows/cols and issuing `TIOCSWINSZ` on every frame sends a
`SIGWINCH` storm; full-screen TUIs (vim, tmux, an agent CLI's own UI) redraw on each one and the
terminal visibly stutters.

```
during drag       at most one resize per 33ms per pane, and only if (rows, cols) changed
on mouseUp        commit fractions to the model, then one authoritative resize after 50ms
window live resize  same path, driven from viewDidEndLiveResize + a throttled inFlight timer
```

Only panes whose **character grid** changed are notified — a 3pt drag that does not cross a cell
boundary produces zero PTY traffic.

**Drag session mechanics**

- Drag begins on `mouseDown` in a `DividerFrame.hitRect`; the overlay takes the mouse.
- Cursor is set via `addCursorRect` (`.resizeLeftRight` / `.resizeUpDown`) so it changes on hover.
- The applied-delta return value keeps the divider under the cursor when clamped, instead of the
  cursor drifting away from a stuck divider.
- `⌥` while dragging switches to `.push` mode mid-drag.
- Double-click on a divider → `equalize(container:)` for that container only.
- `Esc` during a drag cancels and restores the starting fractions.

---

## 7. Direct manipulation: drag a pane to rearrange

The tile header is the drag handle. `NSDraggingSession` with a custom pasteboard type
`com.ultra.pane`.

While dragging over a target pane, an overlay shows five drop zones:

```
┌─────────────────────────┐
│  ╲        top        ╱  │   centre 40% × 40% → swap(paneID, target)
│    ╲───────────────╱    │   outside it, the pane's DIAGONALS pick the edge
│ left │   center   │right│   → move(paneID, toEdgeOf: target, edge:)
│    ╱───────────────╲    │
│  ╱       bottom      ╲  │
└─────────────────────────┘
```

**The diagonals, not physical distance.** Outside the centre, the winning edge is the nearest
side measured in *normalised* units — which is exactly the rect's diagonals, the rule people
already know from window snapping. Physical distance would let a wide pane's short top band
swallow most of its left band, so a click 40pt from the left edge would read as "top".

The highlight is an `NSGlassEffectView` tinted with the accent colour, sized to preview where
the pane will actually land (a half for an edge, the whole pane for a swap) — chrome floating
above content, exactly where glass belongs. Under Reduce Transparency it becomes a solid
high-contrast fill rather than being quietly dropped. Dropping a pane on itself is refused.

Dropping on the window's own outer edges to split the root is not implemented yet.

---

## 8. Undo, persistence, restore

**Tracing.** `ULTRA_TRACE=1` logs every structural change, every persist with its caller, and
every close with an abbreviated call stack. Panes disappearing without the user asking is the
worst failure this app can have, and it is the failure least likely to leave evidence — so the
evidence is built in, gated behind an environment variable and free when off.

**Undo.** One `UndoManager` per tab. Every structural mutation registers the previous
`LayoutTree` (it is a value type — snapshotting is a retain, not a deep copy). A divider drag
registers exactly one undo entry, on commit. Menu titles are specific: "Undo Split Pane",
"Undo Close Pane", "Undo Resize Panes".

**Persistence.** `LayoutTree` is `Codable`. Per workspace:

```
~/Library/Application Support/Ultra/
  workspaces/<workspace-uuid>.json      { tree, panes: [PaneID: PaneDescriptor], tabs, window frame }
```

Written atomically (`Data.write(to:options:.atomic)`) and debounced 500 ms after the last change.
A `PaneDescriptor` is `{ kind, title, cwd, command?, tileState }` — enough to rebuild the pane,
never a serialized process.

**Restore.** Tree and frames are restored first and synchronously, so the window appears in its
final geometry with no visible reflow. Shells then spawn into their panes asynchronously with the
recorded cwd/command. A pane whose cwd no longer exists restores with an inline error state and an
"open elsewhere" action — it never silently falls back to `$HOME`.

**Schema versioning.** The JSON carries `version`. Migration is a pure function per version step,
each with a fixture test. An unreadable file is moved aside to `<name>.corrupt-<date>.json` and a
default layout is used — never a silent data loss, never a launch failure.

---

## 9. Keyboard

Defaults; all remappable in Settings (M8). Verbs are exposed as `NSMenuItem`s so they are
discoverable, remappable by the system, and reachable from the Help menu search.

| Shortcut | Action |
|---|---|
| `⌘D` | Split right |
| `⇧⌘D` | Split down |
| `⌥⌘D` | Split left |
| `⌥⇧⌘D` | Split up |
| `⌘W` | Close focused pane (`⇧⌘W` closes the tab) |
| `⌘⌥ ← → ↑ ↓` | Move focus (spatial, § 5) |
| `⌃⌘ ← → ↑ ↓` | Resize focused pane's nearest divider by 16pt (`⇧` → 1pt) |
| `⇧⌘↩` | Toggle zoom on the focused pane |
| `⌘=` | Equalize the focused pane's container (`⌥⌘=` equalizes everything) |
| `⌘1`…`⌘9` | Focus pane N in visual order |
| `⌃⇧` + drag | Rearrange without grabbing the header |

Terminal panes are first responders and swallow most keys. These bindings live on the **menu**,
which gets first crack at key equivalents before the responder chain — so they work even while a
full-screen TUI has the keyboard. Any binding that a user's shell needs (e.g. `⌥←` for word-jump)
is checked against this table in the settings UI, which flags the conflict.

---

## 10. Accessibility

Not a milestone — a property of every step. The engine gets it nearly free because the geometry
is explicit.

- `SplitCanvasView` publishes `NSAccessibility.Role.splitGroup`.
- Each `DividerFrame` is a real accessibility element with `.splitter` role and its `fraction` as
  `AXValue`, so VoiceOver's standard increment/decrement resizes panes with no custom action.
- Each pane surface is an `AXGroup` titled by its tile ("Shell — ultra-swift", "Ports").
- Focus changes post `.focusedUIElementChanged`; splits and closes post `.layoutChanged`.
- Every operation in § 2 is reachable from the menu and § 9 — the engine is fully operable with
  no pointer.
- **Reduce Motion** → structural changes snap; no fraction animation.
- **Increase Contrast** → dividers render as opaque separators instead of subtle hairlines.
- **Reduce Transparency** → see `02-DESIGN-LANGUAGE.md`; the canvas backdrop goes solid.

---

## 11. Testing

Layers 1 and 2 are pure, so this is ordinary unit testing with no window server and no timing.
Swift Testing (`@Test`), run by `swift test`.

**Property tests** over random operation sequences (split / close / resize / move / swap):

- Invariants 1–5 hold after every operation.
- Fractions always sum to 1 within 1e-9, no matter how long the sequence.
- `close` after `split` restores the exact prior tree (round-trip).
- Encode → decode → encode is byte-stable.

**Layout tests**:

- Frames **exactly tile** the container: union of frames plus gutters equals bounds; no pane
  overlaps another; no gap wider than the gutter.
- All edges land on pixel boundaries for scale 1, 2, and 3.
- Golden fixtures: named trees ("3-across", "grid-2x2", "deep-nest") → expected frames.
- Resize clamping at `minPaneSize` boundaries, both `.hardStop` and `.push`.
- Zoom → un-zoom is geometrically identical to the original.

**Navigation tests**: fixture grids with asserted targets for every direction from every pane,
including the non-overlapping fallback and directional memory round-trips.

**Integration (M2+, XCTest with a window)**: assert a PTY's pid is unchanged across 100 random
layout operations. This is the executable form of the product's core promise.

---

## 12. Implementation order for M1

1. `UltraLayout`: types + `normalize()` + invariant assertions. Tests first.
2. `split` / `close` + property tests. No UI yet.
3. `layout()` + pixel rules + golden tests.
4. `SplitCanvasView` + `PaneSurfaceStore` with **placeholder colored panes**. Splitting and
   closing work by keyboard only.
5. `DividerOverlayView`: hit-testing, cursor rects, drag, clamping, `Esc`, double-click.
6. Focus + spatial navigation + directional memory.
7. Zoom, equalize, `⌘1`…`⌘9`.
8. Undo, persistence, restore, schema versioning.
9. Drag-to-rearrange with drop zones.
10. Accessibility pass: AX roles, VoiceOver walkthrough, full keyboard-only operation.

Ship M1 as an app that splits colored rectangles beautifully. Then, and only then, put a
terminal in one.
