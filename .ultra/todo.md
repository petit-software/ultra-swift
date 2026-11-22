- [x] ❯ tun settings to follow vertical navigation.

## Settings: vertical navigation

- [x] Pick Central Icons for the eight Settings panes
- [x] Check the filled Central Icons for the eight Settings panes
- [x] Settings lists its panes down a sidebar — General, Appearance, Terminal, Tiles, Agents, Chat, About, and Tuning in Ultra Dev — instead of tabs across the top; the window is one size, 750 × 560, and each pane scrolls inside it (`UltraSettings`, `SettingsPane`)
- [x] Each pane's icon in the Settings sidebar is a white glyph on a rounded square, in one of the Customize sheet's colours — never the accent, which is white (`SettingsPaneIcon`, `SettingsPane.tint`)
- [x] No bar across the head of a Settings pane: the pane's name is not drawn, the titlebar is transparent with no hairline, and the pane starts at the top of the window (`SettingsWindowChrome`)
- [x] Search at the head of the Settings sidebar: typing lists the options it finds — by label, section, pane or a keyword — each with where it is, in place of the panes; the first found is shown at once and choosing one shows its pane (`SettingsSearch`, `UltraSettings.searchResults`)
- [x] The Settings sidebar's icons are the app's own drawings, eight SVGs kept as text and read by AppKit, drawn in white on each pane's plate; the SF Symbol only if one cannot be read (`SettingsIcons`)
- [x] The Settings window keeps its traffic lights: only the toolbar's background is hidden, not the toolbar, which took them with it (`UltraSettings`, `SettingsWindowChrome`)
- [ ] Try in Ultra Dev by hand: the Settings sidebar in light and dark, the traffic lights,, the search field — typing, the arrow keys into the results, clearing it —, the arrow keys moving down it, and the tall panes — Tiles, General — scrolling

## Compact grid: no line along the window's edge

- [x] In the compact grid a cell against the window's top edge has no top hairline and one against its bottom edge no bottom hairline; with the session belt under the panes the bottom row keeps its line. The hairline is a path now, not the layer's border, which is four sides or none (`PaneContainerView.openEdges`, `SplitCanvasView.openEdges(of:in:)`)
- [ ] Try in Ultra Dev by hand: the compact grid's top and bottom rows with the sidebar open and hidden, a zoomed pane, and a pane in a window of its own

## Mark as Inactive: any project

- [x] Any project can be marked inactive — working, asking, or with no agent at all — not only one whose turns have finished; it stays put away until a new turn begins in it (`AgentStateTracker.putAway`, `AgentMonitor.markInactive`)
- [x] Mark as Active undoes a mark made by hand: File ▸ Session, the palette and the sidebar row's right-click, where the item says which way it will go (`PaneCommands.markSessionActive`)
- [ ] Try in Ultra Dev by hand: Mark as Inactive on a working project, an asking one and one with no agent; Mark as Active after each; a new turn bringing a marked project back

## Ultra Remote: an agent pane on the phone, over Tailscale

Planned, not started. The design is `docs/06-REMOTE.md`.

- [ ] R0 — `Packages/UltraRemoteProtocol`: message types, JSON codec, version negotiation, pairing and challenge signing; iOS and macOS, importing nothing of ours
  - [ ] Round-trip and signature tests, headless
- [ ] R1 — The server, read-only (`Sources/Ultra/Remote/`)
  - [ ] Remote Access on and off: a menu item, a palette command, a Remote pane in Settings; off by default
  - [ ] `RemoteServer`: an `NWListener` WebSocket bound to the Mac's Tailscale address only, rebinding as Tailscale comes and goes
  - [ ] Pairing: the approval sheet with its six-digit code, the paired devices in the keychain, Tailscale's `whois` shown when it answers
  - [ ] The live `panes` list — agent panes only — from `AgentMonitor`
  - [ ] `attach`: the output observer on `ShellTerminalView.dataReceived`, the 256 KB ring buffer, snapshot then live bytes
  - [ ] A command-line test client, and a headless loopback test
- [ ] R2 — Input
  - [ ] Binary frames from the client into the pane's process (`sendRemoteInput`)
  - [ ] The pane's header shows a phone is attached
  - [ ] A property test: no remote message resizes or closes a pane
- [ ] R3 — The iOS app (`Apps/UltraRemote/`)
  - [ ] Connect and pair
  - [ ] The agent list, grouped by project, "needs you" first, live
  - [ ] The terminal: SwiftTerm at the Mac pane's size, fit to width, pinch and pan
  - [ ] The keyboard and its key bar: Esc, Tab, Ctrl, arrows, Return
  - [ ] Gone and disconnected banners, reconnect
  - [ ] Previews for all three screens
- [ ] R4 — Hardening
  - [ ] Revoke a device
  - [ ] Keep the Mac awake while agents work and Remote Access is on — a setting
  - [ ] TestFlight build
  - [ ] Try by hand: Ultra Dev on the Mac, the app on a phone, the Mac out of reach

## Full screen: the window is the screen

- [x] No grey bar across the top of a full-screen window: the window AppKit hosts the titlebar in along the top of the screen is made transparent, and shown again while the menu bar is down; the main window only (`FullScreenTitlebar`, `WindowChrome.hidesFullScreenBar`)
- [x] The sidebar's toggle moves to the leading edge in full screen, where no traffic lights are, centred over the projects' icons — and the first pane's header reserve with it (`RootView.toggleLeading`, `UIState.isFullScreen`)
- [x] No rounded corners in full screen: the window's surface and the sidebar's are square (`WindowSurfaceView`)
- [x] In the compact grid the panes start at the window's top edge, not 2pt under it — in a window and in full screen; in full screen the window's controls sit on the headers' middle (`WindowBarControls.canvasTop`, `RootView.barLine`)
- [x] With the menu bar brought down in full screen, the titlebar shows under it as a bar with its traffic lights, over the top of the window's content; the content does not move (`FullScreenTitlebar.sync`)
- [x] The bar that comes down in full screen is one opaque colour from edge to edge, with a one-pixel hairline along its foot; both follow light and dark (`FullScreenBarBacking`)
- [ ] Try in Ultra Dev by hand: full screen with the sidebar open and hidden, compact and relaxed grid, the menu bar revealed, and back out to a window

## Context: a click selects at once, Space shows what is selected

- [x] A click on a Context row selects it on the click, not after the double-click interval (`ContextRow`)
- [x] Space shows the SELECTED file in Quick Look, not the first: the panel is given the selection when it takes this pane as its controller (`ContextHostingView.beginPreviewPanelControl`)
- [ ] Try in Ultra Dev by hand: click rows in Context, Space on the third, ↑ ↓ with the panel up, a double click still sends
