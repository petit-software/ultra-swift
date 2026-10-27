## Drops, Agents row, Todo footer

- [x] A file dropped on a shell pane lands as its escaped path, typed and not submitted (`ShellQuote`, `ShellTerminalView`)
- [x] The sidebar's Agents selection capsule is as tall as a project's: the row is filled to the list's minimum before the gap goes under it
- [x] The Agents icon is grey in the sidebar row and the belt tab, selected or not
- [x] The Todo footer's clear-all button, after the path, is `minus.circle.fill`; the menu item matches
- [x] The Agents view's empty-state surface wears an unfocused pane's frost and no lift, not the focused pane's (`PaneContainerView.showsFocus`)

## Context: select, Quick Look, double-click sends

- [x] A click on a Context row selects it; a double click sends its `@path` to the shell (`ContextModel.selection`, `ContextRow`)
- [x] Space on the focused Context pane opens the selected file in Quick Look, Space or Esc closes it; ↑/↓ move the selection, in the pane and in the panel; ↩ sends the selected file (`ContextHostingView`)
- [x] Pane ▸ Context ▸ Quick Look, ⌘Y: the menu and palette path to the same preview (`context.quickLook`)
- [x] The Context list lives in the factory, like Todo's, so a command can reach the pane's selection (`TileFactory.contextModel`)

## Palette: projects and sessions

- [x] New Project…, Open Project… and New Shell Session are registry commands, so the palette finds them by "project" and "shell" (`project.new`, `project.open`, `session.newShell`)
- [x] Next Session and Previous Session are registry commands, in the palette as "Next Project" too (`session.next`, `session.previous`)
- [x] Go to Session: one palette entry per open session, by its name, and the same list under View ▸ Go to Session (`PaneCommands.sessionJumps`)

## Menu cleanup


## Tabs and footers


## What's New


## Notify when an agent goes quiet

Today a notification fires only when the agent PROCESS exits (`AgentCompletionTracker`),
which an interactive `claude` or `codex` never does between turns. The sidebar already
knows the state that matters — `AgentStatusTracker` turns "agent owns the tty and has
printed nothing for 5 s, or for 1 s after a BEL" into `needsInput` — so the notification
hangs off that transition rather than a new detector.


## After the notifications


## Notification permission

The settings footer says switching notifications on asks macOS for permission, but nothing
asked until the first notification was due, and that one was posted before the answer came
and refused. Ultra never appeared in System Settings ▸ Notifications.


## Simulator pane, properly


## iPhone remote, part 1: the channel

An iPhone that controls Ultra from anywhere: sees every session and pane, types into any
shell, starts and closes panes and sessions, and is told when an agent is waiting. Nothing in
Ultra talks to a network today, but every fact and verb the phone needs already exists:
`AgentMonitor` samples every pane's status each second, `ShellWorkspace.Registry` knows every
session and pane, `ShellTerminalView.dataReceived` is the one path every terminal byte takes,
`ShellPaneFactory.inject` is the one way bytes go in, and sessions already outlive their
windows (`SessionList.relinquish`), so a Mac with every window closed is still a Mac to
control. Same discipline as `AgentChannel`: a small closed message set, Codable, one line of
JSON per message, refused rather than clamped.

Two facts of the platform shape the whole thing. iOS kills a background socket within
seconds of the app leaving the screen, so "tell me when claude is waiting" while the phone is
in a pocket can only arrive as a push, and the only push with no server of ours is CloudKit.
And nothing in Apple's frameworks crosses a NAT, so reaching the Mac from a café is either
Tailscale (nothing to build; the Mac has a stable name) or a relay someone runs. The plan
takes Tailscale for the bytes and CloudKit for the push, and builds the channel so a relay
could be slotted in later without touching the protocol.

- [ ] `UltraRemote` target (Foundation + UltraLayout + UltraCore only, builds for iOS too): the wire types. Mac → phone: `hello` (Mac name, protocol version, what the phone may do), `sessions` (every workspace with title, directory, pane list with kind/title/cwd/status, cols/rows per shell), `status` (one pane changed), `turnEnded` (agent, duration, session, rang bell), `snapshot` (pane, plain text), `output` (pane, bytes), `refused` (reason). Phone → Mac: `subscribe`/`unsubscribe` (pane). Length-prefixed JSON; a decoder test per message.
- [ ] Move `AgentStatus` and `AgentPaneSample` down into `UltraRemote` (they import nothing but Foundation and UltraLayout) so the phone speaks the same enum; `UltraTerminal` re-exports them under the old names as it does `AgentDefinition`
- [ ] `UltraCore` builds for iOS: add `.iOS(.v26)` to `platforms`, fence `NewProject.swift` (uses `Process`) and `WorkspaceLaunch` behind `#if os(macOS)`; `swift build` on the Mac stays green
- [ ] Pairing, `RemotePairing` in `UltraRemote`: a 6-digit code shown on the Mac, turned into a 32-byte key by both sides (HKDF over code and a random salt the Mac sends in the clear), kept in each Keychain. One code pairs one phone; a paired phone is listed by name and can be forgotten. Pure functions, tested.
- [ ] `RemoteListener` in the app target: `NWListener` on a fixed port the user can see (default 7777), TLS-PSK with the paired device's key so an unpaired device cannot complete a handshake, and a failed handshake from the same address backs off (1 s, 2 s, 4 s…). Bonjour `_ultra._tcp` for the LAN; on every interface, so a Tailscale address works too. Off by default; started and stopped by the preference.
- [ ] `RemoteBroadcaster` in the app target: builds `sessions` from the registry on connect and on any store change (new pane, pane closed, title or cwd moved, session opened or closed); publishes `status` from `AgentMonitor.observeStatuses` only when a pane's status moved; publishes `turnEnded` beside `announce`
- [ ] Output tee: `ShellTerminalView.onOutput: ((ArraySlice<UInt8>) -> Void)?` called from `dataReceived`, nil until a phone subscribes to that pane, so an unwatched Mac does no extra work. `subscribe` sends `snapshot` (`historyText`) then live `output`, coalesced to at most ~30 frames a second per pane.
- [ ] Keep-alive both ways every 10 s; the Mac drops a connection silent for 30 s. The phone reconnects on its own with the same back-off as the listener uses on failures.
- [ ] Settings ▸ Remote: toggle "Let my iPhone control this Mac", the pairing code with a Pair button, the port, the Mac's addresses (LAN and, when present, the Tailscale one), the paired devices with Forget. Menu item Ultra ▸ Pair iPhone… with a key path, so the palette has it.
- [ ] `NSLocalNetworkUsageDescription` and `NSBonjourServices` in the Mac Info.plist; nothing in entitlements: not sandboxed, and the hardened runtime does not gate sockets
- [ ] Tests: wire types round-trip; pairing derives the same key from the same code and salt and different keys from different codes; the broadcaster sends `status` once per change and nothing on a quiet tick; the tee is nil with no subscriber and fires per chunk with one; a connection with the wrong key is refused before any message

## iPhone remote, part 2: the phone as a terminal

- [ ] Xcode project `UltraPhone` (iOS 26) over the local package: `UltraRemote` + SwiftTerm. Discovery: Bonjour on the LAN, plus an address book of Macs by host and port for everything else (a Tailscale MagicDNS name goes here once). Pair with the code; the key lives in the phone's Keychain.
- [ ] Sessions screen mirroring the sidebar: title, folder, rolled-up status dot in the same three colours; a pane list per session with each pane's kind, title and status
- [ ] Pane screen: SwiftTerm's iOS `TerminalView` fed the snapshot then the live stream. Its own keyboard and accessory bar (Esc, Ctrl, Tab, arrows) already produce the right bytes; every `send` from the view becomes an `inject`. Nothing of ours translates keys.
- [ ] The grid is the Mac pane's, not the phone's. The phone renders at the Mac's cols and rows, scaled to fit the width, with pinch to zoom and pan. The PTY is never resized from the phone: a reflow would hit the Mac pane too, and two sizes for one pty is no size.
- [ ] Wire: phone → Mac `inject` (pane, bytes). The Mac refuses a pane that is not running and any message over 4 KB; `inject` goes through `ShellPaneFactory.inject`. Typing is allowed by a second preference, "Let my iPhone type into shells", off until the first is on and advertised in `hello` so the phone hides its keyboard rather than fail.
- [ ] While bytes arrive from a phone, the Mac pane's header shows a small phone glyph for a few seconds, so someone at the Mac can see the input did not come from its keyboard
- [ ] Reconnect: the phone keeps the last `sessions` greyed with "Not connected" and tries again; on reconnect every open pane re-subscribes and gets a fresh snapshot
- [ ] Tests: `inject` for an unknown or exited pane is refused; a message over the cap is refused; typing off at the preference is refused even from a paired phone; the phone's model re-subscribes after a drop
- [ ] Pair a real phone on Wi-Fi, run `claude` in a pane, watch the status flip on the phone, answer its permission prompt with `y` from the phone

## iPhone remote, part 3: controlling the workspace

Verbs for what the Pane and Session menus do. Still a closed set, still no "run this
command": the phone has a shell for that.

- [ ] Wire: `newPane` (session, kind: shell or agent, agent name), `closePane` (pane), `newSession` (directory, from `recentDirectories()` which the Mac sends in `hello`), `closeSession` (session), `raise` (session). Each maps to the command the menu already fires; `closePane` and `closeSession` are refused for a pane with an agent still working unless the message says `force`.
- [ ] A shell made from the phone with no Mac window showing the session never gets a first layout, so `onFirstLayout` never starts it. The broadcaster calls `startPendingShells()` for a pane the phone created, at a default 120×40, and the Mac pane resizes it when a window does show it.
- [ ] `newSession` while every Mac window is closed: `ShellWorkspace.make` without a window, the store held in the registry as a relinquished session is, so the next Mac window adopts it with `adoptRunning`
- [ ] Phone UI: + on the sessions screen lists recent projects; + on a session lists Shell and the project's agents; swipe to close a pane or a session, with the "agent still working" confirmation
- [ ] Phone todo view, read-only: the session's `.ultra/todo.md` sent as text in `sessions` and redrawn when it changes, because the plan is what you check from the sofa
- [ ] Tests: each verb reaches its command; close refuses a working agent without `force`; a pane created with no window starts its shell; a session created with no window is adopted by the next window

## iPhone remote, part 4: anywhere, and a pocket

- [ ] Docs: `docs/06-REMOTE.md` with the protocol, the pairing, and the one-page Tailscale setup (install on both, the Mac's MagicDNS name goes in the phone's address book, nothing else). Linked from Settings ▸ Remote.
- [ ] Keep the Mac reachable: a third preference, "Stay awake while my iPhone can reach this Mac", holding a `SleepGuard`-style assertion whenever Remote is on and the Mac is on power; off on battery, and said so in the footer
- [ ] CloudKit push: an iCloud container shared by both apps; the Mac writes one `RemoteEvent` record per `turnEnded` (session, agent, duration, text), the phone holds a `CKQuerySubscription` with an alert so iOS shows "claude is waiting in ultra-swift" with the app closed and the phone on cellular. Tapping it opens the pane. Records older than a day are deleted by the Mac.
- [ ] The iCloud entitlement is the first entry in `Ultra.entitlements`; the comment there says why it is load-bearing, as the file asks
- [ ] A phone that is connected gets `turnEnded` over the socket and suppresses the matching push, so one event is one notification
- [ ] Decide after a month of use whether a relay is worth running for people without Tailscale; the protocol does not change either way

## iPhone remote, part 5: ship

- [ ] Phone build on the real device from Xcode, then TestFlight from an archive step added to `scripts/release.sh`
- [ ] Ultra release with Remote in it; the phone and Mac check protocol versions in `hello` and say which one to update

## Chat: copy an answer


## Move a pane to its own window


## Simulator: a soft enclosure, a finish, and Edit / Preview

Xcode's chrome is a flat slab with an outline, and one body serves whole generations
(17, 17 Pro and 18 Pro all draw `phone11`). Its GEOMETRY is right — screen inset, corner
radius — so that is kept and the artwork is replaced. A 3D body (first in Core Animation,
then in Metal with a studio light and a shadow) was built, looked at, and taken out: a
drawing of a phone round a phone, when the pane is for the app.


## Agent states in the session list

Five states, a glance each, each with how long it has held: working (a turning arc),
needs you (an orange ringed dot), done and not read yet (a filled check, the name in bold),
done (a small check), inactive (a moon, the name dimmed). Rows with no agent history stay
clean.


## Simulator pane switched off

- [ ] Bring it back when a touch reliably reaches a device that was already running when the pane connected

## Agents overview: every working agent's pane, on one canvas

One overview for the whole app: every pane with an agent in it, from every session in
every window and from the sessions a closed window left running, brought together on one
canvas to be watched and typed into. Not a picture of the panes — the panes themselves.
The mechanism exists: Move Pane to New Window hands a live surface from one canvas to
another (`PaneSurfaceStore.handOver`, `LayoutStore.sendToNewWindow` / `takeBack`) and
nothing is rebuilt or released on the way, which is property 1. The overview is a canvas
that agent panes VISIT: they come when the view opens or when an agent starts anywhere
while it is up (the monitor's tick, which already notices `claude` typed at a prompt), and
they go home — to the exact place they left — when the view closes, when the agent exits,
or when their wrapper's "Open project" is pressed. In their home canvas the siblings fill
the gap meanwhile, as they do for a pane window.

Each pane sits in a wrapper that says which project it is — the session's icon and name,
the agent's state and age — and carries one verb: go to that project, which takes the pane
home, selects its session and puts the keyboard in it.

It is the row above every session in the sidebar and the first tab on the belt, icon
`rectangle.grid.2x2.fill`, key ⌘0, the entry before the first session for Next / Previous
Session. One overview, in the window that asked for it: asking in a second window moves
it there, since a pane can only be in one place. Panes come from windows that are showing
their session too — the grid is complete or it is not an overview.


## Agents overview, after the first look



## Agents overview, living with it

- [x] Panes on the overview can be dragged into another order, and the order survives a pane coming or going: the grid is laid out again from the tree's reading order
- [x] Typing into an agent is not the agent working: output within a beat of the person's own input is the TUI's echo and does not move `lastOutputAt` (`AgentEcho`); the arc turns only while the agent prints on its own
- [x] The working arc is grey, not white

- [x] "Agent" picked for a project with none set up — from a pane's kind menu or New Pane — opens the session's Customize sheet, where one is added, instead of beeping
- [x] A pane pinned light is a white sheet under frost too: the frost branch of the backdrop had forgotten it, and a browser on a white page sat in a grey frame since frost became the default
- [x] Sidebar: the X leaves the row the overview was opened from; no bold on any row; a hairline parts the Agents row from the projects
- [x] Settings ▸ General loses the Glass panes toggle: frost is the look. The flag stays for the Tuning tab and the tests
- [x] The belt parts its Agents tab from the sessions with a vertical hairline, as the sidebar does

## Agents overview, part 2

- [x] `agents.openWaiting` "Open Waiting Agent", ⌥⌘0: focus the longest-waiting needs-you pane on the overview if it is up, else in its session, raised — the keyboard answer to the orange dot
- [x] A click on the "claude is waiting" notification lands on the pane: on the overview if it is up, else in its session; the notification carries the pane id now
- [x] Menu bar item lists the agents waiting for you, "session › agent", each landing on its pane; a Show Agents entry above them; rebuilt each time the menu opens
- [x] Chat panes with a turn in flight visit too, and stay until the overview closes — the answer arriving is not the chat leaving; the strip says working, then done
- [x] The overview's grid refuses drags, moves and swaps: a computed arrangement; the drag handle is gone from a visitor
- [x] The empty state is a plain surface — no header, no ring, no handle — rather than a pane called "Agents"
- [x] Sidebar and belt: space, not a hairline, parts Agents from the projects
- [x] The running count is the number in a filled circle (`N.circle.fill`, up to 50; the bare number past that)
- [x] Agents wears `circle.grid.2x2.fill` everywhere: the sidebar row, the belt tab, the menu, the empty state and the stand-in
- [x] The Agents demo counts its stand-ins on the sidebar row and the belt tab, as running agents would be
- [x] Drag a visitor by its strip or its header onto another to trade places: on the overview every drop over a pane is a swap (`DropZone.swapTarget`), never an edge or root split
- [x] Pane ▸ Swap ▸ Left / Right / Up / Down, ⇧⌥⌘ and the arrows: the keyboard path to the swap, on any canvas
