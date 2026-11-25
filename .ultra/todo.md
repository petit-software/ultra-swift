## Canvas diagnostics: capture a window showing the wrong panes

- [x] Help ▸ Copy Canvas Diagnostics, and the palette: what every window holds — its projects, the one selected, each canvas in it and where every pane's view is — copied as text and saved under Application Support (`CanvasDiagnostics`)

## Inactive projects across launches

- [x] A project that is inactive — marked by hand, or by the clock — is inactive still when the app opens fresh, through its agents relaunching, until a new turn begins in it or it is marked active (`AgentStateTracker.restoreInactive`)

## Answer window: reply to a waiting agent without coming back to Ultra

- [x] Settings ▸ Agents: when an agent waits, show a notification or the answer window (`Preferences.agentAttention`)
- [x] The answer window: a small floating window, top right, on the window's glass and theme, that mirrors the waiting pane's screen and types into it (`AnswerPanel`)
  - [x] A tab per waiting pane; a bar with Open in Ultra and Close
  - [x] Keys: ⌃⌥⌘A from any app takes and gives back the keyboard; ⌘↩ opens the pane in Ultra, ⌘W closes, ⇧⌘[ and ⇧⌘] change tab
  - [x] View ▸ Show Answer Window (⌃⌘Y), and the palette
