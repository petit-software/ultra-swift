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
  - [x] Keys: ⌘⎋ from any app takes and gives back the keyboard; ⌘↩ opens the pane in Ultra, ⌘W closes, ⇧⌘[ and ⇧⌘] change tab
  - [x] View ▸ Show Answer Window (⌃⌘Y), and the palette
  - [x] The pane itself in the window, not a copy of its text: the selected tab's pane visits a one-pane canvas there — colours, cursor, scrollback, selection, mouse — and goes home when the tab changes or the window closes; the window is larger and resizable (`AnswerPanel.host`)
  - [x] Ultra Dev: View ▸ Demo: Answer Window, the palette, and a button in Settings ▸ Tuning show it on the front project's shells (`AnswerPanel.showPreview`)
- [x] A neutral background the pane's own text cannot be read on — an agent's dark composer left on a light pane, Claude Code's `brightBlack` message block on the light theme — is washed to a tint of the pane as it is drawn, and when the theme changes (`LegibleBackgrounds`)

## Git pane: open a changed file

- [x] A changed file opens in the editor from its row — a button on hover, and the row's right-click menu, which also has Open All Changed Files and the row's other verbs by name (`GitTile.openFile`)

## Right-click menus in the panes

- [x] File tree: a row's menu gains Expand/Collapse, Go to Folder in Shell, Open in Default App, Copy Relative Path, Copy Name, Rename… and Move to Trash; the pane's own menu has New File, dotfiles, Reload and the folder's verbs
- [x] Todo: a task's menu (done, edit, send, copy, remove), a section's (target, fold, rename, remove) and the pane's (progress, fold all, open and reveal the list, clear)
- [x] Context: a row's menu (send, open in editor, pin, copy reference and path, reveal, remove) and the pane's (add, send all, copy all, clear unpinned)
- [ ] Ports, Resources, Editor and Chat have no right-click menu yet

## Browser: Web Inspector opens

- [x] The footer's button, ⌥⌘I and right-click ▸ Inspect Element open Web Inspector: the web view's configuration turns on `developerExtrasEnabled`, which `isInspectable` alone does not (`BrowserSession.webView`)

