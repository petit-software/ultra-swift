
## New shit
- [x] Add option to settings apperance to turn off glass from panes. — Settings ▸ General ▸ Appearance ▸ Glass panes; off, a pane is a solid sheet of the system's control background (the theme's navy painted solid came out blue). Not yet confirmed in the running app
- [x] Build and issue a GH release — v0.32.0 published 2026-10-15 at https://github.com/petit-software/ultra-swift/releases/tag/v0.32.0: notarized app and DMG, appcast, deltas and whats-new.md, through the new release.sh
- [x] add option to ultra to always display whats new dialog when new version of ultra is downloaded this should be a super short list of things we added - this should be coming from a release of gh page from ultra but this must be added to the release cycle so it always creates a super short list of things based on original release description. — shown once on the first launch after an update (Settings ▸ Updates, on by default) and on Ultra ▸ What's New in Ultra… any time. The list is `whats-new.md` beside the DMG on the release: `scripts/release.sh` now takes the notes file, makes the list from each paragraph's bold lead, refuses notes with none, and publishes the release with gh. Not yet confirmed in the running app; the first release through the new script will confirm the cycle
- [x] Add editor a light mode like in browser — the footer's sun and moon, Pane ▸ Editor ▸ Toggle Light Editor (⌃⌘L, the browser's and the chat's key), saved with the pane. Not yet confirmed in the running app
- [x] add option to open MD files from system Open with > and Ultra should be there. Markdown files would open in editor. New ultra window would open with just Editor open. — Ultra claims Markdown as an alternate handler; the files open in a new window with one editor pane on no project. Needs a rebuilt Ultra.app for Launch Services to see the new Info.plist; the launch-by-double-click timing is not yet confirmed in the running app
- [x] add option to equalize column height — Equalize Row Heights, beside Equalize Column Widths on the Pane menu, the window bar's ellipsis and the palette. Not yet confirmed in the running app
- [x] Add option after last pill in the bottom project belt with a plus symbol that opens up a new empty project space without a name with just shell Called New shell that user can rename if they want. — the `+` after the last tab, and File ▸ New Shell Session (⇧⌘T); renamed from Customize. Not saved across launches: a session on no folder has nothing to be found by again. Not yet confirmed in the running app
- [x] why chat can't do reddit fetch?
- [x] media files should be openable / viewable in the editor
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
- [x] Markdown opens in reading mode by default — rendered, not raw — with an Edit button in the footer to switch to the text; Settings ▸ Tiles ▸ Editor turns the default off — drawn by MarkdownUI (GitHub layout in the pane's colours, fences coloured by the editor's own highlighter); the footer's pencil/book and Pane ▸ Editor ▸ Toggle Reading Mode (⌃⌘R) switch per file; Settings ▸ Tiles ▸ Editor ▸ Open Markdown as a page. Checked offscreen in light and dark; not yet confirmed in the running app

## Simulator previews in Pane
- [ ] Simulator: spike — SimulatorKit's own `SimDisplayView` (`initWithFrame:` + `setDevice:` build chrome, renderable and digitizer subviews) as the whole tile; keep it only if the first frame arrives without Swift-only calls
- [ ] Simulator: fix the enclosure's rendering and turn `showsEnclosure` back on
- [ ] Simulator: a device booted from the pane stops responding — the view could stay on the boot-screen screenshot with input off; fixed defensively (re-point on any non-live contents, drop the stale still, re-read surfaces on poll), not yet reproduced here

## Tuning
- [x] Files, Add option at the bottom to open a folder in finder us this icon square.fill.on.square.fill
