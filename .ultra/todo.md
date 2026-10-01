
## New shit

## Simulator previews in Pane
- [ ] Simulator: spike — SimulatorKit's own `SimDisplayView` (`initWithFrame:` + `setDevice:` build chrome, renderable and digitizer subviews) as the whole tile; keep it only if the first frame arrives without Swift-only calls
- [ ] Simulator: fix the enclosure's rendering and turn `showsEnclosure` back on
- [ ] Simulator: a device booted from the pane stops responding — the view could stay on the boot-screen screenshot with input off; fixed defensively (re-point on any non-live contents, drop the stale still, re-read surfaces on poll), not yet reproduced here

## Chat: use the ChatGPT and Claude subscriptions
- [x] Chat: a `codex` provider that spawns `codex app-server` over stdio (JSON-RPC: initialize, account/read, thread/start, turn/start) and streams `item/*` events; sign-in through `account/login/start` type `chatgpt`
- [x] Chat: a `claudeCode` provider that spawns the user's own `claude -p --input-format stream-json --output-format stream-json --include-partial-messages` and streams the deltas; sign-in runs `claude auth login`, which opens the browser itself
- [x] Chat: Settings shows, per engine, who is signed in (`account/read`, `claude auth status`) instead of a key field
- [x] Chat: an engine that is not on PATH is offered with its install command, not hidden
