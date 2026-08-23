# 02 — Design Language

Modern, minimal macOS 26. Liquid Glass, used the way Apple specifies it — which for a terminal
app means using it *less* than you might expect.

Reference: the `liquid-glass` and `ui-review-tahoe` skills in `.claude/skills/`.

---

## Everything is glass

The whole window is one material. There is no opaque layer anywhere in it.

| Surface | Material |
|---|---|
| Window background | **Nothing.** Fully clear, `isOpaque = false`. |
| Every pane | `NSGlassEffectView`, rounded, with the tile's content *inside* it |
| Terminal cells | `backgroundOpacity = 0` — the default background is not painted at all |
| Tile headers | **No fill.** A label floating on the pane's own glass |
| Gutters between panes | Clear — you see through the window between the tiles |
| Window bar, palette, drop indicator | Glass |

**Why there is no window-level material.** A `NSVisualEffectView` behind the panes seems
harmless and is not: the panes' glass then samples *it* instead of the desktop, and the
material collapses into flat grey. The window has to be genuinely clear for the glass to
refract anything. This was the difference between "grey slabs" and glass.

**Why the terminal paints no background.** SwiftTerm's `backgroundOpacity` affects only the
*default* background — text, the caret, selections, and cells with explicit colours stay
fully opaque at any value. So the cells are transparent while the content stays readable,
and `window.isOpaque = false` with a clear `window.backgroundColor` is what lets it composite.

**Half-strength accent has one definition.** `Token.Colour.accentHalf` — the accent at
`accentHalfStrength`, by ALPHA rather than by blending toward it. Half of the way to a
saturated colour still reads as that colour, only darker; half the alpha reads as half. The
focused pane's ring is this token, and anything else wanting a held-back tint should be too,
so a second idea of "half" cannot appear.

**Why the ring is inset.** Drawn on the pane's outer edge it coincides with the glass rim, a
near-white line, and any alpha composited over that reads at full strength however little it
carries. A ring "at 0.5" measured 54% of the way to the accent once it was moved a point in,
and looked like the whole colour before.

**Why headers have no fill.** A header with any background is a second surface, and a second
surface is a seam. The label sits directly on the pane's glass, in the same material as the
terminal beneath it.

> **A note on the record.** This document previously argued the opposite — that glass belongs
> only to the navigation layer and terminal content must stay opaque, for contrast and for
> compositing cost. That concern was raised and overruled: the product is a glass terminal.
> The concern is not wrong in the abstract, so if text legibility becomes a problem over busy
> backdrops, the lever is `TerminalTheme.backgroundOpacity` — raising it from 0 tints the
> cells without giving up the material anywhere else.

## Glass discipline

- **One variant: Regular.** Never Clear — Clear requires media-rich content beneath and has no
  adaptive legibility. Never mix variants in one interface.
- **Never glass on glass.** A control inside a glass tile header is styled with fills and
  vibrancy, not another `.glassEffect()`.
- **One `GlassEffectContainer` per cluster.** Glass cannot sample glass; nearby glass elements
  must share a container to blend correctly. This is correctness, not just performance.
- **Tint only the primary action** — the active-pane accent and the "agent is working" indicator.
  Nothing else is tinted. When everything is tinted, nothing stands out.
- **No steady-state intersections.** In a resting layout, content never sits half-under a glass
  element. Tile headers reserve their own height; they do not float over the content beneath.
- **Strip decorated bars.** No custom bar backgrounds, no borders, no gradients. Hierarchy comes
  from layout and spacing.

## Shape and geometry

## Figure and ground

The single most important thing about the window: **the frame is lighter than the panes.**

`underWindowBackground` samples the desktop, so over a dark wallpaper it lands on the same
value as a dark terminal — and a frame you cannot distinguish from its content is not a frame.
The result was one flat dark rectangle containing more flat dark rectangles, with the glass
present and invisible. The fix is three parts, and all three are needed:

| | |
|---|---|
| **Lift the frame** | A constant `label` tint at 7% over the material puts the chrome deliberately above the panes in value. Dark panes then read as surfaces *set into* a lighter frosted frame. It inverts correctly for a light theme, because the tint derives from the label colour. |
| **Light the frame** | A top-down falloff over that tint gives the window a light source. Material without a gradient reads as grey fill. |
| **Lift the panes** | Each pane casts a soft shadow (heavier when focused) instead of wearing a border. Depth separates surfaces; a box drawn around every pane is what made six panes read as six slabs. |

Gutters are **10pt** and canvas padding **12pt** — wide enough that the material between panes
is actually visible. At 6pt the glass was there and no one could see it, which is the worst of
both.

Tile headers are **not glass**. Glass on a 26pt strip inside every pane read as a grey bar, and
six panes became six bars. A header is a faint `label` tint (3.5%, 7% when focused) over the
pane's own surface: enough to separate the label from the content, without adding a chrome
layer. Glass stays where it belongs — the window bar, the command palette, the drop indicator.

## The window corner is the system's, and that is not negotiable

AppKit masks a titled window to its own corner radius — **measured at 15.5pt on macOS 26** —
and offers no API to change it. Any rounded surface we draw inside that mask appears as a
*second* arc: two concentric curves at every corner.

Escaping the mask requires an untitled window. That was built and tested, and it fails for a
reason no styling is worth: **an untitled window cannot become key.** Verified directly — the
app would not activate (`isActive == false` after `activate(options:)`) and no keystroke ever
reached a shell. A terminal that cannot take the keyboard is not a terminal.

So: the window wears the system's corner, and **we draw no second one**. `RoundedBackdropView`
rounds nothing and strokes no border. One shape, one corner.

The generous radius lives where it is actually seen — the **panes**, at 12pt, six of which are
on screen at once. `paneRadius` is deliberately *not* `systemWindowRadius − canvasPadding`
(3.5pt, and mean-looking): with a 12pt gutter the panes are separate surfaces floating on the
material, not nested containers, so strict concentricity does not apply.

Traffic lights are the system's real buttons, inset from the corner by `trafficLightInset`.
AppKit re-lays them out on resize and full-screen transitions, so the inset is re-applied on
every update rather than set once — otherwise the relayout quietly undoes it.

Concentric radii, computed rather than hard-coded. Change `windowRadius` or `canvasPadding`
and everything inside stays concentric on its own:

```
window            system corner, unstyled by us
  └─ canvas padding 12pt
      └─ pane radius 12pt        floating surface, not a nested container
          └─ tile header         inherits the pane's rounded top corners via its clip
```

| Token | Value |
|---|---|
| Window radius | the system's 15.5pt — not ours to choose |
| Canvas padding | 8pt |
| Gutter between panes | 6pt |
| Divider hairline | 1pt, centered in the gutter |
| Divider hit area | 8pt |
| Tile header height | 28pt |
| Tile body inset | 10pt |
| Pane radius | 12pt, derived — never written as a literal |
| Control corner radius | concentric, never a literal |

## Color and type

- **Semantic tokens only.** No literal colors anywhere outside `UltraDesign`. Every token
  resolves through `NSColor`/`Color` semantic colors so light, dark, Increase Contrast, and
  accent-color changes are automatic.
- **Chrome follows the terminal theme.** The window's `NSAppearance` is pinned to the
  active theme's light/dark, so the titlebar, the backdrop material, the glass tile headers,
  the menus and the palette all resolve to match the panes. Without this the header glass
  samples the light backdrop and the window reads as light chrome bolted onto a dark
  terminal — two surfaces instead of one.
- **Terminal themes are separate** from UI tokens. A terminal theme is 16 ANSI colors plus
  fg/bg/cursor/selection, user-editable, shipped with a default light and dark pair that meet
  4.5:1 for normal text against their own background.
- **Type**: SF Pro Text for chrome (11pt tile titles, 13pt body). SF Mono for terminal, with the
  user's font override respected — never override their terminal font choice for "design".
- **Icons**: SF Symbols 7 only, monochrome by default, `.hierarchical` on hover, never mixed with
  a text label inside a single toolbar group.
- **Scroll edge effect**: hard variant (the macOS default) where a tile body scrolls under a
  glass header. One per edge, and only where floating UI actually exists.

## Motion

- **Structural change is instant.** Split, close, and zoom apply frames with implicit
  CALayer animation explicitly disabled. A 0.18s spring was specified originally; it was cut
  because in a terminal an animating pane reads as lag, not as polish. The frames are correct
  on the very next display refresh.
- **Nothing animates during a divider drag.** Frames follow the cursor exactly.
- Focus change is instantaneous — a 100ms focus animation reads as lag in a terminal.
- The only ambient motion is the agent-activity indicator, and it stops when idle.

## Accessibility

Free at the system level if the rules above are followed, but verified explicitly:

| Setting | Behavior |
|---|---|
| **Reduce Motion** | Structural changes snap. System reduces glass lensing automatically. |
| **Increase Contrast** | Glass renders with a contrasting border; dividers become opaque separators. |
| **Reduce Transparency** | Canvas backdrop and all glass surfaces go solid. Verified as a first-class appearance, not a degraded one. |
| **VoiceOver** | See `01-SPLIT-ENGINE.md` § 10. |
| **Full keyboard access** | Every action reachable without a pointer; visible focus ring on all chrome controls. |
| **Dynamic type in chrome** | Tile headers and tile bodies scale; the terminal grid does not (it follows the terminal font setting). |

## Anti-references

Inherited from the Electron app's `PRODUCT.md`, and still correct: no decorative SaaS-dashboard
styling, no oversized controls, no gratuitous cards, no novelty interactions, and no visual
effect that competes with terminal work. If a design choice draws the eye away from the pane the
user is typing into, it is wrong.
