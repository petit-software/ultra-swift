## Menu cleanup

- [x] Move New Shell/Agent/Tile Pane and Change Pane To from File into Pane ▸ New Pane / Change Pane To
- [x] Move Next/Previous/Move Session from File ▸ Session into View
- [x] Point registry menu paths and the docs at the new places
- [x] Build and test

## Tabs and footers

- [x] Editor shows its file tabs only with more than one file open
- [x] Chat pane gets tabs for several chats, hidden with one
- [x] Every footer's light/dark toggle sits last, after a small separator
- [x] Editor caret visible in light mode
- [x] Build and test

## What's New

- [x] Drop the launch-time What's New sheet; Ultra ▸ What's New in Ultra… stays

## Notify when an agent goes quiet

Today a notification fires only when the agent PROCESS exits (`AgentCompletionTracker`),
which an interactive `claude` or `codex` never does between turns. The sidebar already
knows the state that matters — `AgentStatusTracker` turns "agent owns the tty and has
printed nothing for 5 s, or for 1 s after a BEL" into `needsInput` — so the notification
hangs off that transition rather than a new detector.

- [x] `AgentTurnTracker` in UltraTerminal: per pane, remember when `working` began; on `working → needsInput` emit a turn-ended event with the agent's name, the pane, and how long the turn ran. Pure and tested, like the two trackers beside it.
- [x] Fold it into `AgentMonitor.observeStatuses`, which already has every pane's status each second
- [x] Policy, in `AgentCompletionPolicy`: notify only when the turn ran at least the minimum (30 s, the existing threshold), the app is not being watched (`isWatching`), and the setting is on. One notification per turn: a pane stays quiet until the next `working`, so the transition fires once by construction.
- [x] A BEL within the bell window makes the turn-end a report rather than a guess: let it through at a shorter minimum (5 s), since the agent asked. Permission prompts ring too, which is exactly when the user is wanted.
- [x] Message: "<agent> is waiting" / "Worked for 2m 10s in <session name>" — a turn end is a request for input, not a completion, and the session name says which window to go to
- [x] Clicking the notification raises the window and selects the session (`SessionList.raise`), then acknowledges the badge
- [x] Settings: rename the toggle to "Notify me when an agent finishes or waits for me"; keep one switch, not two
- [x] Stop the idle rule mis-firing on a long tool call: a build that prints nothing for 5 s looks like a turn end. Raise the quiet threshold for the NOTIFICATION only (15 s) while keeping the sidebar's 5 s dot, and let a BEL cut it short.
- [x] Tests: a working agent that goes quiet for the threshold notifies once; more output before the threshold does not; a quiet shorter than the minimum turn does not; the watched app does not; a BEL shortens the wait

## After the notifications

- [x] Drop the finished-agent badges from the sidebar; a system notification is the only word on a finished turn
- [x] A new user's first window is one shell pane (already so: no saved document and no default layout opens `LayoutTree(single:)`; nothing to change)
- [x] Commit, push main, GitHub release

## Notification permission

The settings footer says switching notifications on asks macOS for permission, but nothing
asked until the first notification was due, and that one was posted before the answer came
and refused. Ultra never appeared in System Settings ▸ Notifications.

- [x] Ask for permission when the toggle turns on, and at launch when it is already on
- [x] Post each notification from inside the authorization callback so the first is not dropped
- [x] Build and test
- [x] Ultra 0.35.0: bump, commit, push, GitHub release

## Simulator pane, properly

- [x] Device frame on: Xcode's composite body where the chrome has one (phone14/15), nine-part edges stretched rather than tiled (the iPad's faded side bands), per screen for a two-screen device
- [x] Rotation: `devicectl device orientation rotate`, and the screen turned by its `uiOrientation`, which the pane never read
- [x] iPhone Duo: show whichever screen is active (`devicectl device info displays`), fold and unfold through SpringBoard's display tool from a small simulator-side helper
- [x] Footer: the device picker moves into it; power, URL, zoom and appearance stay
- [x] Floating controls over a running device: Home, Lock, Screenshot, Fold; hold ⌥ for Rotate Left/Right, with a hint in the corner on hover
- [x] Menu items with key paths for Rotate Left/Right, Fold/Unfold and Show Device Frame
- [x] Previews, tests, docs
- [x] Build, test, and run the fresh build as its own window

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

- [x] A copy icon under every finished answer copies the whole answer, every turn of it, and ticks for a moment
- [x] Pane ▸ Chat ▸ Copy Last Answer (⇧⌥⌘C), dimmed while an answer is arriving or before there is one
- [x] Tests for what an answer's text is

## Move a pane to its own window

- [x] A pane can leave the canvas for a window of its own, in the same session: same project, same shell, same agent socket — only its view moves
- [x] Pane ▸ Move Pane to New Window, with a key, and the same item on the pane's header menu
- [x] The window closes back: closing it returns the pane to the canvas rather than killing it; Pane ▸ Move Pane Back to Main Window (⇧⌘M in a pane window) does the same from the keyboard
- [x] Persisted: a detached pane and its window frame come back on the next launch
- [x] Tests, build, previews

## Simulator: a soft enclosure, a finish, and Edit / Preview

Xcode's chrome is a flat slab with an outline, and one body serves whole generations
(17, 17 Pro and 18 Pro all draw `phone11`). Its GEOMETRY is right — screen inset, corner
radius — so that is kept and the artwork is replaced. A 3D body (first in Core Animation,
then in Metal with a studio light and a shadow) was built, looked at, and taken out: a
drawing of a phone round a phone, when the pane is for the app.

- [x] `DeviceFamily` from the device type, and `DeviceFinish`: the real finishes of each generation, with a fallback for a device newer than the list
- [x] `DeviceEnclosure`: a soft body in the finish's colour with black glass set into it, from Xcode's geometry; no cameras, buttons or ports, no shadow
- [x] Colour dots over the top of the device switch the finish; Next/Previous Finish in the palette; the finish is saved with the pane
- [x] Edit / Preview: ⌃⌘E, the pill's first control, the footer; in Preview nothing reaches the device; saved with the pane
- [x] Tests, previews, docs

## Agent states in the session list

Five states, a glance each, each with how long it has held: working (a turning arc),
needs you (an orange ringed dot), done and not read yet (a filled check, the name in bold),
done (a small check), inactive (a moon, the name dimmed). Rows with no agent history stay
clean.

- [x] `AgentState` + `AgentStateTracker` in UltraTerminal: quiet becomes done only after the turn tracker's silence or a bell; done is unread until its session is looked at; an hour after that it is inactive
- [x] `AgentPrompt`: "needs you" read from the bottom of the agent's screen — a question over a numbered menu, a y/n — so a finished agent and an asking one are told apart
- [x] Each agent sample carries the screen's last lines; `AgentMonitor` folds readings and the viewed sessions (key window's selected session, or its pane window) into states, and a once-a-minute clock for the ages
- [x] Sidebar row: age column and symbol in the trailing slot, bold name while unread, dimmed when inactive, the state spoken to VoiceOver
- [x] Tests for prompts (Claude Code's box, Codex's "Allow command?", y/n, a finished screen) and every transition; a preview of the five states

## Simulator pane switched off

- [x] `TileFactory.offersSimulator` off: no pane kind, no Pane ▸ Simulator menu or palette commands, the agent `simulator` verb refuses, AGENTS.md stops advertising it, a saved Simulator pane opens as a shell
- [ ] Bring it back when a touch reliably reaches a device that was already running when the pane connected
