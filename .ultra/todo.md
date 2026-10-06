
## New shit
- [x] Command pallete, add optoin to close the Project
- [x] CMD + W should cloase all panse-as it is doing now but last is left closing it should be possible and that should close the whole project.
- [x] Opening a project presevers a previously selected project panes instead of showing a fresh set of new project — fixed in code: a closed window left its sessions running where no window showed them, and File ▸ Open on one of those found it "open", had no window to raise and did nothing. A closing window now lets go of its sessions; the next window, or opening the project, takes them back still running. Not yet confirmed in the running app
- [x] Chat: on white theme, send button stays white - instead of reversing to oopposite balck color.
- [x] CHat: sometimes sending a message make schat blank for a few seconds - why? must be fixed — the transcript was a lazy stack: it guessed the height of rows it had not built and scrolled to the bottom of the guess, an empty stretch, until the first piece of the answer re-laid it out. Now a plain stack; reproduced and checked offscreen, not yet confirmed in the running app
- [x] Chat : spinning sparkle is slow it should be dynamic 1 runthen pause then again etc, now it's spinning super slow. Use animations skill to do it right.,
- [x] chat pane - both WebSearch and WebFetch were refused for lack of permission.  - enable those
- [x] when bottom nav is enabled + and folfder icons should be 2pt smaller
- [x] for browser, add thiny 0.5px airline right below the header and on top of the footer
- [x] Add option to open multiple tabs in the browser pane
- [x] Sometimes click on ptoject names in the bottom switcher don't refresh the view and old projects panes are still persistent. — fixed in code: a click that travelled 4pt became a tab drag and selected nothing; the outgoing canvas now also drops its panes. Not yet confirmed in the running app
- [x] Add option to ellipsis to equal column width that make 3 col to be 33, 4 calls to be 25 etc this should be one extra option first at the top with separator below

## Simulator previews in Pane
- [ ] Simulator: spike — SimulatorKit's own `SimDisplayView` (`initWithFrame:` + `setDevice:` build chrome, renderable and digitizer subviews) as the whole tile; keep it only if the first frame arrives without Swift-only calls
- [ ] Simulator: fix the enclosure's rendering and turn `showsEnclosure` back on
- [ ] Simulator: a device booted from the pane stops responding — the view could stay on the boot-screen screenshot with input off; fixed defensively (re-point on any non-live contents, drop the stale still, re-read surfaces on poll), not yet reproduced here

