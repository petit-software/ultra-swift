# 06 — Ultra Remote: an agent pane on the phone, over Tailscale

> **Status: a plan. Nothing here is built.** The tasks are in `.ultra/todo.md` under
> "Ultra Remote".

## What it is

A small iOS app that does one thing: pick an agent pane running in Ultra on the Mac, see its
terminal, and answer it from the phone's keyboard. The phone reaches the Mac over the
user's own Tailscale network.

The case it is for: an agent is waiting on a permission prompt, or has finished and wants
the next instruction, and the person is not at the Mac.

## What it is not (v1)

- Not a remote Ultra. No layout, no splits, no tiles, no sidebar, no opening or closing panes.
- Not for plain shells. Only panes with an agent in them are listed.
- No push notifications, no web client, no Android, no file transfer.
- No Tailscale code inside Ultra (`tsnet`). Ultra uses the Tailscale the user already runs.

## The rules it must not break

From `00-OVERVIEW.md`, restated for this feature:

1. **A PTY survives everything, a phone included.** Attaching, detaching, a dropped
   connection or a crashed client never creates, resizes, signals or closes a pane's process.
2. **The remote never resizes the PTY.** The pane on the Mac keeps its columns and rows. The
   phone draws the terminal at the Mac's size and fits it to its own screen.
3. **Off until switched on.** No listener exists until the user turns Remote Access on, and
   never on any interface but Tailscale's.
4. **Keyboard first.** Turning it on, approving a phone and revoking one are menu items and
   palette commands before they are Settings controls.

## How it works

```
 iPhone (Tailscale app on)                    Mac (Tailscale on)
 ┌──────────────────────┐   WireGuard    ┌───────────────────────────────┐
 │ Ultra Remote         │◄──────────────►│ Ultra                         │
 │  pane list           │   WebSocket    │  RemoteServer (NWListener,    │
 │  SwiftTerm view      │   on 100.x     │   bound to the tailnet addr)  │
 │  keyboard + key bar  │                │  ├ AgentMonitor → pane list   │
 └──────────────────────┘                │  └ ShellTerminalView → bytes  │
                                         └───────────────────────────────┘
```

### Transport

- Ultra listens with `NWListener` and the WebSocket protocol on one fixed port
  (default 47600, changeable in Settings), bound to the Mac's Tailscale address only: the
  interface whose address is in `100.64.0.0/10` (or `fd7a:115c:a1e0::/48`).
  `NWParameters.requiredLocalEndpoint` does the binding; a path monitor rebinds when
  Tailscale comes and goes. No Tailscale address, no listener — Settings says why.
- The phone connects to the Mac's MagicDNS name (`mac.tailnet.ts.net`) or its `100.x`
  address with `NWConnection`. Tailscale's WireGuard tunnel is the encryption; the
  WebSocket inside it is plain. (`tailscale cert` and TLS are a later hardening step.)

### Who may connect

Being on the tailnet is not enough: a shared or work tailnet has other people on it.

- **Pairing.** A phone Ultra has not seen sends `hello` with a device name and a public
  key. Ultra shows a sheet — "Bart's iPhone wants to control agents in Ultra" with a
  six-digit code the phone also shows — and the user approves or denies. Approved, the key
  goes in Ultra's keychain; the phone keeps its private key in its own.
- **Every later connection** is a challenge signed with that key (CryptoKit, Curve25519).
- **Tailscale identity, when we can get it.** Ultra asks the local Tailscale daemon who
  owns the connecting address (`tailscale whois --json <ip>`, or its LocalAPI socket) and
  shows the answer in the approval sheet and the device list. Missing or failing, pairing
  still works without it.
- **Seen on the Mac.** While a phone is attached to a pane, that pane's header shows it,
  and Settings ▸ Remote lists the paired devices with Revoke.

### Protocol

One WebSocket. JSON text frames for control, binary frames for terminal bytes. Versioned
from the first message, so a newer phone and an older Ultra can refuse each other politely.

| Direction | Message | What it carries |
|---|---|---|
| phone → Mac | `hello` | protocol version, device name, public key |
| Mac → phone | `challenge` / `paired` / `denied` | nonce to sign; or the pairing result |
| phone → Mac | `auth` | the signed nonce |
| Mac → phone | `panes` | every agent pane: id, project name and colour, pane title, agent name, state (working / needs you / done / inactive) and since when. Sent on connect and again whenever it changes |
| phone → Mac | `attach` | pane id |
| Mac → phone | `attached` | columns, rows, then a binary snapshot |
| Mac → phone | binary | PTY output for the attached pane, as it arrives |
| Mac → phone | `resized` | new columns and rows when the Mac's pane changes size |
| phone → Mac | binary | keystrokes for the attached pane, as bytes |
| phone → Mac | `detach` | — |
| Mac → phone | `gone` | the attached pane closed or its agent exited |

One attached pane per connection. The list is what `AgentMonitor` already computes for the
sidebar (`terminalsBySession`, `stateByPane`), filtered to panes with an agent.

### The terminal on the phone

- The iOS app renders with **SwiftTerm**, the same emulator Ultra uses; it has a UIKit
  `TerminalView`. The phone is a second emulator fed the same byte stream, so colours,
  cursor, and the keyboard mode the agent asked for (Claude Code turns on the kitty
  keyboard protocol) come out the same without Ultra translating anything.
- **Output tap.** `ShellTerminalView.dataReceived` already sees every byte. It gains an
  optional observer, set only while a phone is attached; with none attached the cost is one
  nil check.
- **Snapshot on attach.** The phone joins mid-stream, so it needs the screen as it stands.
  v1: each agent pane keeps a ring buffer of its last 256 KB of output while Remote Access
  is on; attach sends a terminal reset and replays the buffer. If replay proves unfaithful
  (see Risks), the fallback is to serialise SwiftTerm's screen buffer — text and attributes
  — into escape sequences.
- **Size.** The phone's emulator is set to the Mac pane's columns and rows and scaled to
  fit the phone's width, with pinch to zoom and pan. Landscape fits most panes readably.
- **Input.** The system keyboard, plus a key bar above it with what a phone lacks: Esc,
  Tab, Ctrl, the arrows, and Return. SwiftTerm encodes the keys; the bytes go to the Mac
  and into `process.send` — the same path as typing at the Mac.

### The iOS app, screen by screen

1. **Connect.** First run: the Mac's Tailscale name, then the pairing code. After that it
   reconnects by itself. If Tailscale is off on the phone, it says so and links to it.
2. **Agents.** One list, grouped by project: agent, pane title, state and age — "needs you"
   first. Pull to refresh is not needed; the list is live.
3. **Terminal.** The pane, full screen, with the keyboard and key bar. Back returns to the
   list. A banner when the pane is gone or the connection dropped, with reconnect.

That is the whole app. SwiftUI, iOS 26, portrait and landscape.

## Where the code goes

- **`Packages/UltraRemoteProtocol`** — a new local Swift package, iOS and macOS, importing
  nothing of ours: the message types, the JSON codec, the version, pairing and signing.
  Pure, tested headless. A separate package rather than a target of the main one so the
  main package stays macOS-only.
- **`Sources/Ultra/Remote/`** — `RemoteServer` (listener, connections, pairing, the device
  store), `RemotePaneFeed` (ring buffers, the output observer, input), `RemoteCommands`
  (menu items and palette), and a Remote pane in Settings. It lives in `Ultra` because it
  needs `AgentMonitor` and the workspace registry, which nothing may import.
- **`Sources/UltraTerminal/ShellTerminalView.swift`** — the output observer and a
  `sendRemoteInput(_:)` that writes to the process.
- **`Apps/UltraRemote/`** — the iOS app's Xcode project, depending on
  `UltraRemoteProtocol` and SwiftTerm. Its own bundle id, `software.petit.ultra.remote`.

## Milestones

Each is shippable or demoable by itself.

**R0 — Protocol package.** Message types, codec, version negotiation, pairing and
challenge signing. *Accept when* round-trip and signature tests pass in `swift test`.

**R1 — Server, read-only.** Remote Access on/off (menu, palette, Settings); the listener
bound to the tailnet address; pairing sheet and device store; the live `panes` list;
`attach` with snapshot and live output. *Accept when* a command-line test client on
another tailnet machine lists agent panes and prints one pane's output as it happens, and a
headless test does the same over loopback.

**R2 — Input.** Binary frames from the client reach the pane's process; the pane header
shows a phone is attached. *Accept when* the test client answers a Claude Code permission
prompt, and a property test shows no remote message can resize or close a pane.

**R3 — iOS app.** Connect and pair, the agent list, the terminal with keyboard and key
bar, reconnect. *Accept when*, on a real phone with the Mac out of reach, an agent's prompt
can be read and answered, and a new instruction typed and sent.

**R4 — Hardening.** Revoke; rebinding as Tailscale comes and goes; a power assertion that
keeps the Mac awake while agents work and Remote Access is on (a setting); connection
loss on a train; TestFlight build. *Accept when* a day of real use turns up no stuck
connection and no pane harmed.

**Later, not planned here:** push notifications when an agent needs you, a "take over
size" mode that fits the PTY to the phone, TLS with `tailscale cert`, plain shells, a web
client.

## Testing

- Protocol: pure, headless, in the package's own tests.
- Server: an in-process client over loopback in `swift test` — the listener takes its
  bind address as a parameter so a test can use `127.0.0.1`. PTY output needs async tests
  paced with `Task.sleep`, as the existing PTY suites are.
- iOS: the terminal screen against a fake server replaying a recorded session; previews
  for all three screens. Never driven live on the user's own simulator device.
- By hand: Ultra Dev on the Mac, the app on a phone, both on the tailnet.

## Risks and open questions

- **Snapshot fidelity.** Replaying the last 256 KB may start mid-escape-sequence or miss
  state set earlier (scroll regions, modes). Agents repaint often, which hides most of it,
  but this is the part most likely to need the buffer-serialising fallback.
- **A wide pane on a narrow screen.** Fit-to-width on a 200-column pane is unreadable in
  portrait. Zoom and pan make it usable, not pleasant; "take over size" is the real answer
  and is deferred because it breaks rule 2 unless designed carefully.
- **A sleeping Mac is unreachable.** The power assertion in R4 covers a Mac on power; a
  closed laptop on battery will still sleep.
- **Tailscale's daemon.** The App Store and standalone builds of Tailscale expose the CLI
  and LocalAPI differently. Identity lookup is therefore optional by design.
- **Distribution.** TestFlight first. An App Store listing needs review of an app that is
  useless without a Mac app and a third-party VPN — worth asking before promising.
- **Sandbox and entitlements.** Ultra needs the incoming-connections entitlement under the
  hardened runtime; the iOS app needs none beyond the network.
- **Is LAN without Tailscale wanted?** Not planned: it would need our own encryption, and
  Tailscale is the point.
