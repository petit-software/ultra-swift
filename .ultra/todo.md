## Canvas diagnostics: capture a window showing the wrong panes

- [x] Help ▸ Copy Canvas Diagnostics, and the palette: what every window holds — its projects, the one selected, each canvas in it and where every pane's view is — copied as text and saved under Application Support (`CanvasDiagnostics`)
- [x] A selected project whose canvas is missing from the window is given one: looked at a moment after each selection, rebuilt when it is not there, counted in the diagnostics (`CanvasWatch`)
- [ ] Find what closes the `AttributeGraph` cycle at launch that leaves the detail column on its placeholder — seen once, 0.40.24 opening after an update, not reproduced in Ultra Dev

## Inactive projects across launches

- [x] A project that is inactive — marked by hand, or by the clock — is inactive still when the app opens fresh, through its agents relaunching, until a new turn begins in it or it is marked active (`AgentStateTracker.restoreInactive`)

## Agents follow a light/dark switch

- [x] A pane tells the program in it when its theme turns light or dark — DEC mode 2031, `CSI ? 997 ; 1|2 n`, and the `CSI ? 996 n` query — so Claude Code on its Auto theme recolours its composer with the pane (`ColorSchemeReports`)

## Answer window: reply to a waiting agent without coming back to Ultra

- [x] Settings ▸ Agents: when an agent waits, show a notification or the answer window (`Preferences.agentAttention`)
- [x] The answer window: a small floating window, top right, on the window's glass and theme, that mirrors the waiting pane's screen and types into it (`AnswerPanel`)
  - [x] A tab per waiting pane; a bar with Open in Ultra and Close
  - [x] Keys: ⌃⌥⌘A from any app takes and gives back the keyboard; ⌘↩ opens the pane in Ultra, ⌘W closes, ⇧⌘[ and ⇧⌘] change tab
  - [x] View ▸ Show Answer Window (⌃⌘Y), and the palette
- [x] A neutral background the pane's own text cannot be read on — an agent's dark composer left on a light pane, Claude Code's `brightBlack` message block on the light theme — is washed to a tint of the pane as it is drawn, and when the theme changes (`LegibleBackgrounds`)
