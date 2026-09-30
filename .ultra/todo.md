
## New shit
- [ ] Browser pane: a pane that opens a URL
- [x] File tree: New File crashed the app (persist re-entered the pane being built)
- [x] Editor: open files as tabs along the top, not a sidebar
- [x] Editor: generic code colouring, language detected from the file name or shebang
- [x] Tab belt: bigger add and open icons with more gap between them
- [x] Editor: a diff opened over another diff (`.ultra/todo.md` from Git) stays on Loading…

## Simulator previews in Pane
- [ ] Simulator: spike — SimulatorKit's own `SimDisplayView` (`initWithFrame:` + `setDevice:` build chrome, renderable and digitizer subviews) as the whole tile; keep it only if the first frame arrives without Swift-only calls
- [ ] Simulator: fix the enclosure's rendering and turn `showsEnclosure` back on
- [ ] Simulator: a device booted from the pane stops responding — the view could stay on the boot-screen screenshot with input off; fixed defensively (re-point on any non-live contents, drop the stale still, re-read surfaces on poll), not yet reproduced here
