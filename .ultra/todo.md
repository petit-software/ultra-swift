
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
