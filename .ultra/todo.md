- [ ] ❯ tun settings to follow vertical navigation.

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
