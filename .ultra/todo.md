
## Sidebar, light mode and floating panes

- [x] A window that takes a session from another comes to the front, and one that would land exactly on the window it left — that window fills its screen — is 80% of the screen instead, so it is seen to be another window (`WorkspaceModel.adoptWindow`, `SessionList.covers`)
- [x] A project row's right-click has no Show / Hide Active Sessions when the project has none to list
- [x] A light terminal theme is drawn through CoreGraphics even with "Draw terminals on the GPU" on: the Metal renderer clears to the background's RGB at zero alpha, unpremultiplied, which on a light theme burns every glyph's antialiased edge to white (`ShellTerminalView.drawsOnGPU`)
- [x] The zoomed pane's header icon, and the Todo's progress toggle, are ink: black on a light pane, white on a dark one (`accentInk`)
- [x] A pane floats over the canvas: Pane ▸ Float Pane lifts it off the tiling into a canvas of its own in the same window, moved by its header's band and resized from its sides and bottom corners; Pane ▸ Dock Pane puts it back; saved and restored with the session (`LayoutStore.floatPane`, `FloatingPanes`, `PaneWindowLayout.floats`)
- [x] A `…` menu at the far right of a pane's header: Zoom Pane, Float Pane or Dock Pane, Move Pane to New Window
- [x] Pane ▸ Focus Next Floating Pane takes the keyboard round the tiling and each floating pane: one canvas has it at a time, and the Pane menu acts on that one (`LayoutStore.activeCanvas`, `cycleCanvas`)
- [ ] Try in Ultra Dev by hand: the row's Move to New Window from the right-click menu, a floating pane's shell taking keys, and light-mode text with the GPU setting on

## Palette, header and floating panes: second pass

- [x] View ▸ Toggle Light and Dark Mode, and the palette: from Follow System it goes to the opposite of what the Mac shows (`view.toggleAppearance`)
- [x] The palette's pane commands read "Add Git Pane", "Add Todo Pane", … instead of "New … Pane"
- [x] The zoom button is off the pane header: zoom is in the `…` menu, which every header has — a visiting pane's too — and which wears the ink while its pane is zoomed
- [x] A floating pane is 90% opaque
- [x] A floating pane stays on the canvas: pushed past an edge, it rests inside it by `floatMargin`, measured to the pane itself (`LayoutStore.floatFrame(_:fitting:)`, `floatMargin`)

## Floating panes: glass and focus

- [x] A floating pane's surface is Liquid Glass — the regular glass, whatever Settings says for tiled panes (`PaneContainerView.floatsOnGlass`)
- [x] Chrome buttons — a footer's `+`, a header's controls — never take the keyboard, so a pane handed the first responder puts no focus ring on one (`ChromeIconButton`)
- [x] A floating pane rests 16pt inside the canvas's edges, not 8 (`LayoutStore.floatMargin`)
- [x] A floating pane sits in a glass frame, 8pt wide all round, that moves it when dragged; its four corners resize it (`FloatFrameGrips`, `LayoutStore.floatFrameWidth`)
- [x] A floating pane is opaque again: glass, and no translucency over it
- [x] Dragged past an edge a floating pane gives a quarter of the way, and springs back inside when let go (`floatFrame(_:pulledPast:)`, `isFloatHeld`)
- [x] A floating pane's frame shows only under the pointer, and while it is being dragged

## Floating sidebar

- [x] The sidebar floats: the split view's own column glass, drawn in from the window's edges by the window padding and given a pane's corners, with the traffic lights on it (`SidebarColumnChrome`, `SessionSidebar.panelInset`)
- [x] No divider, no shadow and no surface of its own under the sidebar: the window's surface runs unbroken round the panel and the panes
- [x] The sidebar's panel is the colour of the panes: a pane's frost and unfocused wash, or the panes' glass with Glass panes on (`PaneSurface`)
- [x] The selected row is the neutral wash on the sidebar's glass, not a glass capsule of its own (`SelectedProjectWash`)
- [ ] Try in Ultra Dev by hand: the floating sidebar in dark mode, collapsed and reopened, a row dragged, and in full screen

## Sidebar without a background, controls by the traffic lights

- [x] The sidebar has no background: the window's surface is laid inside the column again, flush with the window, and the pane-coloured panel is gone (`SessionSidebar`, `PaneSurface` removed)
- [x] The sidebar toggle is beside the traffic lights, level with them; ⌘, `+` and `…` are in the sidebar's top right corner, on the same line — all drawn in the title band rather than as toolbar items (`RootView.sidebarToggle`, `RootView.windowBarMenus`, `SessionSidebar.headControls`)
- [x] The sidebar is 290pt at its narrowest and 480pt at its widest; dragged narrower it hides. Neither limit was ever applied: `toolbar(removing: .sidebarToggle)` drops a column width set inside it, so the width is now set outside it (`RootView`, `WindowBarControls.sidebarMinWidth`)
- [x] The canvas runs to the top of the window, a window padding in from it, sidebar open or hidden; the project's name is off the main window and there is no title band (`RootView.canvasTopInset`, `SplitCanvasView.topInset`)
- [x] With the sidebar hidden only the sidebar's button stays beside the traffic lights, and the pane in the window's top-left corner moves its header's close and name clear of both (`RootView.canvasCornerReserve`, `SplitCanvasView.cornerReserve`, `PaneContainerView.headerLeadingInset`)
- [x] A pane under the transparent titlebar is not pushed down by its safe area (`SplitCanvasView.cancelTitlebarSafeArea`)
- [x] The window's `…` menu is grouped into submenus — Arrange Panes, Layout, Windows — and has Switch Color Mode ▸ Light, Dark, System, the current one ticked (`ColourModeMenu`)
- [x] View ▸ Switch Color Mode ▸ Light, Dark, System, and the three in the palette (`PaneCommands.colourModes`)
- [x] Grid Mode ▸ Relaxed / Compact. Compact: no gutters between the panes and no inset from the window's edges, square corners, no surface or shadow of a pane's own — every pane the same on the window's surface —, no focus ring, and a hairline round each; the settings are kept for Relaxed. View ▸ Grid Mode, the window's `…` menu, the palette (`Appearance.GridMode`, `canvasGutter`, `canvasPadding`, `canvasPaneRadius`, `PaneContainerView.isBare`, `PaneCommands.gridModes`)
- [x] The traffic lights, the title band's controls and the top row of pane headers are one line in either grid mode: 26pt down under the unified titlebar in Relaxed, 20pt under the compact titlebar in Compact, where the panes start 2pt down to meet it. The system places the lights; nothing moves them by hand, which made the zoom button slide during a sidebar collapse (`WindowBarControls.line`, `WindowChrome.compactTitlebar`)
- [x] Compact: no focus ring — the focused pane is told by its header; and the session belt keeps 12pt from the window's edges and from the panes above it (`RootView.beltPadding`)
- [x] The title band's controls wear a pane header button's colours: the secondary label at rest, the label on a plate under the pointer (`WindowBarControlLook`)
- [x] Unfolding a project in the sidebar is not animated: the cell opens at once, the project's name does not move, and its sessions fade in inside it (`SessionTerminalRows`)
- [x] The selected project in the sidebar is Liquid Glass again; the neutral wash under Reduce Transparency (`SelectedProjectWash`)
- [x] A pane's header keeps 44pt between its name and its controls to be picked up by: a long name — an agent at work — took the whole band, and a floating pane could not be moved by its header (`PaneHeader.minDragBand`)
- [x] Back in the Relaxed grid the title band's controls return to the traffic lights' line: their height was read inside a modifier that was never run again (`WindowBarControlStyle.line`)
- [ ] Try in Ultra Dev by hand: full screen, where the traffic lights are gone and the titlebar is a window of AppKit's own — the controls, and the corner pane's header; the sidebar's edge against the canvas in light mode; a pane's header at the top of the window — its buttons, dragging it, and a browser or editor pane there; dragging the window, by the sidebar's head and with the sidebar hidden; the Agents overview with the sidebar hidden
