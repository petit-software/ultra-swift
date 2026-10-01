
## New shit
- [x] Add a greeting in a different language to each of the three test files.
- [x] Create `test2.md` and `test3.md` in the project root.
- [x] Create `test.md` in the project root.
- [x] All the notification lik Reloaded - the file hcnaged on disk - mapp all of them and prepare a new desig of a toast that floats in the bottom of pane abve footer around 4pt from borders of the pane using glass capsue.
  - [x] Toast: map every notice — Editor (reloaded, conflict + Reload, failed), Todo (reloaded, could not save), Browser (load failed + Retry), Simulator (failed) — onto one `TileNotice` value, so the words are written once
  - [x] Toast: `TileToast`, a glass capsule floating 4pt above the footer and 4pt in from the pane's sides, replacing the top strip; an informational one leaves on its own, one that needs a decision stays
  - [x] Toast: the four tiles on it; `NoticeBar` gone
  - [x] Toast: tests for the mapping; docs (tiles, design language)
  - [x] Toast: a key path for Close — the strip never had one either; a Pane ▸ Dismiss Notice command
- [x] make sure we have a nice animation for when agent is thinking in chat pane you can use spinning arrow extract it from system icon. thinking can be shown instead of stop button, but when you hover over thinking it shows stop button to stop it.
  - [x] Chat: the thinking mark is the four-pointed star (`ThinkingStar`, traced from the design's SVG), turning half a revolution and resting; it zooms in when the answer starts and shrinks away when it is in
- [x] make sure light mode correctly colors my bubble messages.
- [x] I want chat pane to display files it changed in a visual way always the same height with the name and diff +/- number. if multiple files changed display them stacked in bordered rounded table in rows with the same info as singular - singular should use th e same table rounded treatment allow clicking on each file and open in editor.
  - [x] Chat: `ChatFileChange` (path, +/−) on a tool call — counted from Claude Code's Edit/Write arguments and Codex's unified diff
  - [x] Chat: one rounded, bordered table per answer with a fixed-height row per changed file: name, folder, +/−; a click opens it in the editor
  - [x] Chat: tests for the counts and the grouping; docs
- [x] Chat: clicking a newly created empty file in the changed-files table showed an error — the editor now watches for a file it could not read and takes it when it appears, empty or not; opening it again reads it again
- [x] Toast: rounded at 12pt (`Token.Space.toastCornerRadius`) rather than a full capsule
- [x] file editor, can we have a proper markdown support for files with md extension?
  - [x] Editor: `MarkdownHighlighter`, a line-at-a-time scanner for `.md` — headings, emphasis, code spans and fences, links, bullets, task boxes, quotes, rules, front matter
  - [x] Editor: bold and italic faces for headings and emphasis, same size so lines keep their height; tests; docs
- [x] file editor: the line-number ruler's edge runs past the tabs and the footer; it should stop at the tab row (or the header, with no tabs) and at the footer
- [x] opening new projects keeps pane from previous project open
  - [x] Storage: one document per project — `load(directory:)` takes the newest, `retireDuplicates` parks the rest in `workspaces/stale/`
  - [x] New window: opens the first start project that is not open already, restored; a twin of an open project is not saved

## Simulator previews in Pane
- [ ] Simulator: spike — SimulatorKit's own `SimDisplayView` (`initWithFrame:` + `setDevice:` build chrome, renderable and digitizer subviews) as the whole tile; keep it only if the first frame arrives without Swift-only calls
- [ ] Simulator: fix the enclosure's rendering and turn `showsEnclosure` back on
- [ ] Simulator: a device booted from the pane stops responding — the view could stay on the boot-screen screenshot with input off; fixed defensively (re-point on any non-live contents, drop the stale still, re-read surfaces on poll), not yet reproduced here

## Chat: use the ChatGPT and Claude subscriptions
- [x] Chat: a `codex` provider that spawns `codex app-server` over stdio (JSON-RPC: initialize, account/read, thread/start, turn/start) and streams `item/*` events; sign-in through `account/login/start` type `chatgpt`
- [x] Chat: a `claudeCode` provider that spawns the user's own `claude -p --input-format stream-json --output-format stream-json --include-partial-messages` and streams the deltas; sign-in runs `claude auth login`, which opens the browser itself
- [x] Chat: Settings shows, per engine, who is signed in (`account/read`, `claude auth status`) instead of a key field
- [x] Chat: an engine that is not on PATH is offered with its install command, not hidden
