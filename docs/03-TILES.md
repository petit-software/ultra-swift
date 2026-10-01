# 03 — Tiles

A pane holds a tile. The split engine gives it a rectangle and nothing else.

```swift
public protocol Tile: Identifiable, Sendable {
    static var kind: TileKind { get }
    var title: String { get }
    var subtitle: String? { get }          // e.g. branch name, cwd basename
    var headerActions: [TileAction] { get }
    func makeSurface(context: TileContext) -> NSView   // NSHostingView for SwiftUI tiles
    func encodeState() -> Data?
}
```

Every tile except Shell is a SwiftUI view in an `NSHostingView`. Shell is AppKit-native. Both go
into the same `PaneSurfaceStore` and are laid out by the same code.

`TileContext` carries the project root, the active worktree path, the focused shell's PTY handle
(for injection), and the workspace event bus.

---

## 0. Where a tile points, and where it types

Two questions every tile asks, and both used to be answered by "whichever pane happened to be
first".

**Where it types.** `injectIntoShell` targets the focused pane when that pane is itself a shell;
otherwise the shell the user was last working in; otherwise the first shell in the layout.
The middle step is the load-bearing one: pressing a control inside a tile focuses the TILE, so
`tree.focused` is the sending tile by the time the send runs. `LayoutStore.lastFocusedShell`
remembers the shell being left as well as the one being entered, because a restored window opens
focused on a shell that nobody ever clicked. Resolution is scoped to ONE workspace by id — with
two tabs open, a tile must not type into the other tab's shell.

**Where it points.** A tile is created on the working directory of the shell it would type into,
which follows `cd`. From then on it is the pane's own folder, recorded in its `PaneRecord.cwd`,
so a restored tile comes back where it was rather than where the project is.

`TileContext.setRoot` moves it. `TileFactory.folderScoped` lists the kinds this applies to —
File Tree and Git — and every other kind ignores it: Ports and Resources attribute by process
ancestry rather than by path, and Todo and Context already have a "where is this list stored"
control that would be a second, disagreeing answer to the same question.

A retarget REBUILDS the tile on the new folder rather than mutating it in place. A Git tile aimed
at another repository shares nothing with the one it was showing — not its branch, not its diffs,
not its expanded folders — and a tile that kept half of the old state would be showing two
repositories at once. The pane keeps its id, its position and its size; only its contents change,
through the same path a pane conversion takes.

Three ways in, one verb behind all of them:

- the folder icon in the footer (`TileFolderMenu`): choose a folder, go up, follow the shell,
  back to the project — greyed rather than hidden when a destination would not move the tile;
- the file tree's `..` row, and "Show Only This Folder" on a directory;
- `Pane ▸ Folder` on the main menu, and so the command palette. Nothing here has a default key
  binding: four chords for a control most panes do not have is four chords nobody remembers.

---

## 1. Shell

The primary tile. A login shell, usually with an agent CLI running in it.

- **Engine**: SwiftTerm's `TerminalView` plus our own `LocalProcess`, as `ShellTerminalView`.
  Not `LocalProcessTerminalView`: it resizes the PTY the instant the grid changes and its
  `sizeChanged` is `public`, not `open`, so the policy cannot be overridden from outside the
  module. Owning the process is ~60 lines and buys the resize coalescing the product needs.
- **Padding**: SwiftTerm draws its grid flush to its bounds and has no content inset, so
  `ShellPaneContainer` paints the theme background across the pane and insets the grid inside
  it — the padding is part of the terminal, not a gap showing the pane behind it.
- **Keyboard**: the container refuses first-responder status; the canvas walks down to the
  first subview that accepts it. Handing a refusing wrapper to `makeFirstResponder` silently
  does nothing, which is exactly how a split leaves the caret in the pane you split away from.
- **Spawn**: `zsh -l` in the pane's cwd. An agent session runs `zsh -l -c "exec <command>"` so
  the CLI inherits the user's full PATH/env and gets a real TTY for its own TUI. This is exactly
  the Electron app's approach and it is the right one — Ultra is a harness, not an agent loop.
- **Agent registry**: `{ name, command }` entries in `<project>/.ultra/agents.json`
  (`ProjectAgents`). A project starts with NONE: no file is written when it is created, and a
  project without the file reads as having no agents, so File ▸ New Agent Pane is empty until
  the user adds one from the session's Customize sheet. `claude`, `codex` and `gemini` stay
  KNOWN — `AgentDefinition.known` — so a pane running one of them still lights the sidebar's
  agent badge whether or not this project lists it. The file is committed, like the todo
  list: which agents a project is worked on with travels with the checkout.
  Availability probed with `command -v` through a login shell, once per binary per launch;
  unavailable agents are shown disabled with the binary they were looking for.
- **Agent pane**: its own `PaneRecord.Kind` (`agent`), built by the same factory as a shell —
  a shell whose `command` is one of the registry's entries, launched with `exec` as above. Being
  a kind is what lets "Agent" sit beside "Todo" in every pane menu, name itself in the header,
  and be told apart from a plain shell in a layout. File ▸ New Agent Pane lists the project's
  agents; ⌥⌘A and the palette's "New Agent Pane" open the first installed one. A `shell`
  record written before the kind existed, carrying a command, restores as an agent.
- **Resize**: driven by the coalescing rules in `01-SPLIT-ENGINE.md` § 6.
- **Scrollback**: kept in the live `Terminal` for the process lifetime. On quit, the last N lines
  are written to `~/Library/Application Support/Ultra/scrollback/<paneID>.txt` and restored as
  inert text above the new prompt, clearly marked as a previous session.
- **Header**: cwd basename, agent name, and an activity dot driven by the foreground process
  (`ps -t <tty> -o stat=,command=`) — the same technique as the Electron `process-name.ts`.
- **Injection API**: `inject(_ text: String, submit: Bool)` writes to the PTY master. `submit:
  false` leaves the text at the prompt so the user can add to it. Used by Context and Todo.

## 1b. File tree

The project's files, lazily expanded.

- **Reads one directory at a time** and caches it. A root with a 40,000-file `node_modules`
  costs nothing until someone opens that folder.
- **Flat row array, not a recursive `OutlineGroup`** — the list only ever holds what is
  visible, and expansion is testable without a view.
- **Collapsing forgets descendants' open state**, so reopening a folder does not explode back
  to a tree the user just closed.
- **Clicking a file opens it in the editor; double-clicking reveals it in Finder.** The
  first click is not held back to wait for a second — the editor opens at once, and the
  second click of a double adds the reveal. Sending a file's shell-quoted path to the
  focused shell, without submitting, is on the hover pill and the context menu.
- **Hovering a row floats Open, Send and Reveal** over its trailing end, on the same glass
  pill as Todo, Git and Context rows. The same three on files and folders: Open puts a file
  in the editor and re-roots the tree on a folder (a click already expands it in place).
  All three are also on the row's context menu.
- **New File** in the footer — the editor's own verb (⌃⌘N), offered where you notice the
  file is missing. It opens an untitled tab; see § 1c for where its first save goes.

## 1c. Editor — the small one

Essential only. This is the editor for fixing a typo in a config file without leaving the
terminal, not a replacement for the one the user already has. Everything past this list is
something another editor does better.

- **Open, edit, save.** ⌘S is taken by the text view itself, because the app's ⌘S saves the
  LAYOUT and while you are typing in a file that is not what the keystroke means.
- **New File** (⌃⌘N, Pane ▸ Editor, the palette, the footer). An untitled tab in the editor
  a clicked file would have landed in, or a new editor pane when there is none, with the
  caret already in it. It has no path until its first ⌘S, which opens the save panel on the
  project's `.ultra/` folder with a free name (`untitled.md`, `untitled-2.md`) — a file
  started here is nearly always a note about the project, and that is where those live. The
  panel is only a default; the file goes wherever it is taken. `.ultra/` is made if the
  project has none, and removed again if the save is cancelled.
- **Tabs along the top**, one per open file or diff, in the order they were opened. A row
  of tabs rather than a sidebar: a sidebar took a column off a pane that is already as
  narrow as the user made it, and hid itself below 400pt, which is where most editor panes
  live. ⇧⌘] / ⇧⌘[ move along the row; ⌃⌘W closes the tab showing. The selected tab is
  scrolled into view when the row is longer than the pane.
- **Generic colouring** (`CodeHighlighter`): comments, strings, numbers, keywords,
  capitalised types and `@`/`#`/`$` attributes, from a table of a dozen facts per language
  (`CodeLanguage`) and one linear pass — not a grammar. The language comes from the file's
  name, or from a shebang when the name says nothing; a file in a language the table does
  not know is plain text. System colours only, so it reads in both appearances.
- **Markdown** (`MarkdownHighlighter`) is the one file kind the table cannot describe — it
  has no comments, strings or keywords — so `.md` (and README, CHANGELOG) gets a scanner of
  its own, a line at a time: headings bold and coloured, `**strong**` bold, `*emphasis*`
  italic, code spans and fenced blocks (which swallow everything inside them, so a `#` in
  a shell snippet is not a heading), links with their destinations receding, bullets,
  numbers, task boxes, quote marks, rules, front matter and HTML comments. The face stays
  monospaced and 12pt, so a heading does not change the height of its line. Not CommonMark:
  the common cases, and an odd one is plain text rather than wrong colour.
- **Line numbers**, drawn per VISIBLE line — a 50,000-line file costs the same to scroll as
  a 50-line one.
- **Smart substitutions off.** Curly quotes and em dashes silently replacing what you typed
  is a bug generator in a config file. This is why it is `NSTextView` and not SwiftUI's
  `TextEditor`, which inherits them and cannot carry a ruler either.
- **Binary files are refused**, not shown as garbage that looks editable and corrupts on
  save. A NUL byte in the first 8KB is the test.
- **A file that is not there yet** — clicked in a chat's list of changes before the engine
  has written it — opens on a "could not read" toast, watches its folder, and becomes the
  file the moment it appears, an empty one included; opening it again reads it again.
- **External changes**: reloaded when there are no local edits, and when there ARE, neither
  side is touched and the user is told. Nothing here overwrites work without being asked.
- **The open file is persisted** in the pane record, so a restored workspace reopens it.
- Reachable from a File Tree pane's context menu — "Open in Editor".

Deliberately absent: per-language grammars, find and replace, multiple cursors,
autocomplete, and split views. Each is a reason to use the editor the user already has.

## 1d. The agent control channel

An agent in a pane can ask the app to do a few things. `ULTRA_AGENT_SOCK` is in its
environment; it writes one line of JSON and reads one line back.

```
$ printf '{"verb":"open","path":"Sources/Main.swift","line":42}\n' | nc -U "$ULTRA_AGENT_SOCK"
{"ok":true}
```

- **Verbs are a closed set** — `open`, `reveal`, `browse` (a web page in a Browser pane,
  `http` and `https` only) and `simulator` (§ 9). No `eval`, no "run this command":
  the agent already has a shell, and a verb list that grows without review is an injection
  surface rather than a feature.
- **A socket, not escape sequences.** An escape sequence lives in scrollback and replays
  every time the buffer redraws, and anything able to write to the tty — `cat` of a hostile
  file, a compiler echoing attacker-controlled bytes — could drive the app. A socket is
  addressed by the process that was handed its path.
- **Every path is resolved against the workspace root and REFUSED if it escapes**, including
  via a symlink that lives inside the tree but points out of it. Refused, never clamped: a
  silent correction hides the attempt.
- **Mode 0600**, so another user on the machine cannot connect.

## 2. Todo — per-project markdown

Todos are files, not app state. They must be readable, diffable, committable, and editable by
the agent running in the next pane over.

- **Location**: `<project>/.ultra/todo.md`, created on first use. If `docs/TODO.md` or `TODO.md`
  already exists at the project root, offer to adopt it instead of creating a second list.
- **Format**: plain GitHub task lists. `##` headings are sections; `- [ ]` / `- [x]` are items.
  Nested items are subtasks.
- **Round-trip is lossless.** Parse into a model that retains every byte it does not own —
  prose, front matter, code fences, blank lines between blocks. Writing back rewrites only the
  task lines that changed. A user's notes between tasks survive a toggle.
- **External edits**: watch with `DispatchSource` on the file descriptor (plus a directory watch
  to survive atomic-replace saves). Reload on change. If the file changed on disk while a local
  edit was in flight (mtime + content hash mismatch), keep both: write the local version and
  surface a non-blocking "reloaded from disk — your edit is in the undo stack" notice.
  Notices are toasts — see § Notices below — never a strip that moves the list.
- **Clear Completed Tasks** — the `xmark.circle.fill` button in the footer, and Pane ▸ Todo in the
  menu and the palette — removes every ticked task line in one edit and nothing else: an
  undone subtask under a done parent stays, prose and headings are not looked at. Dimmed when
  nothing is done. No chord, because it removes lines.
- **A progress bar floating over the foot of the list**, on the toast's glass and in its
  place, 4pt above the footer and 8pt in from the sides: the percentage on the left, the accent's share of a 3pt track, and a close control
  on the right. Ticked tasks over all of them — only task lines count; a heading is not a
  thing to finish, prose and fenced lines are never looked at, and a subtask counts like any
  other box. Hover for the numbers; VoiceOver reads them as the bar's value. Nothing is
  shown for an empty list, and a notice stacks above the bar rather than on it. Closing it is
  remembered per project; the `percent` toggle in the footer, tinted while the bar is up,
  and **Pane ▸ Todo ▸ Toggle Progress Bar** bring it back.
- **Actions**: toggle, add, remove (a **minus** — one line out of a markdown file, not a
  deletion), reorder by drag, indent/outdent, edit in place, and **Send to shell** — injects the
  task text into the focused shell without submitting.
- **Sections from the composer.** A draft that starts with `#` is a section, not a task:
  `# Later` appends `## Later` to the end of the file (one `#` is written as two — a single
  `#` is the document's title, which the list does not show) and points the composer at it,
  so the tasks typed next land at its head. Naming a section that already exists selects it
  instead of making a twin; a bare `#` points the composer back at the top. Clicking a
  heading does the same with the pointer, and the placeholder always says where a task will
  go. A new section goes at the END because a heading claims every task below it.
- **A heading is a row like a task**: pencil or double-click to rename (its level is kept),
  Return on an emptied field or the minus to remove. Removing takes out the heading line
  ONLY — its tasks stay and join the section above. A task dropped on a heading moves to the
  head of that section, which is how an empty one is filled by drag.
- **Which headings are rows.** Every heading opens a group, tasks or not, so a new section is
  visible at once. Not shown: a title over subsections (`# Plan` directly above `## Now`), an
  empty level-one heading opening the file, and a lone level-one heading over the whole list.
- **Editing does not move the row.** The trailing controls sit in fixed-width slots and the row
  keeps one baseline alignment in both modes, so entering edit mode swaps the pencil for Save in
  the same column instead of re-flowing every icon out from under the pointer.
- **Why markdown and not a database**: the agent in the adjacent pane can read and update it with
  no integration work at all. That is the entire point.
- **The agent is told.** A project Ultra creates gets an `AGENTS.md` whose Ultra section names
  this file and says to plan in it. See `AgentInstructions` and `04-ROADMAP.md` § M7.

## 3. Resources

CPU and memory attributed to the panes that caused it.

- **Source**: `ps -axo pid=,ppid=,pcpu=,rss=,comm=`, parsed into a process table. Attribution
  walks the ppid chain from each pane's shell pid, so a `node` process started by an agent in
  pane 3 is charged to pane 3.
- **Poll**: 3s, and **paused when the window is occluded** (`NSWindow.occlusionState`) or the
  app is hidden. A monitoring tile that burns CPU while invisible is self-defeating.
- **Display**: per-pane row with title, CPU %, RSS, and a mini bar; a 60-sample sparkline;
  system totals (load, memory pressure via `vm_stat`/`host_statistics64`) in the footer.
- Sorting by CPU with a stable tie-break, so rows do not jitter between polls.

## 4. Git worktree

The project's dedicated worktree, its branch, and its changes.

- **Always shell out to the system `git`.** Never libgit2. The user's `~/.gitconfig`, aliases,
  hooks, credential helpers, `includeIf`, and signing config must all apply — an embedded library
  silently diverges from what the same command does in the shell next to it.
- **Reads**: `git worktree list --porcelain`, `git rev-parse --abbrev-ref HEAD`,
  `git status --porcelain=v2 --branch` (ahead/behind and per-file state in one call),
  `git diff --numstat` for line counts.
- **Display**: worktree path and branch in the header; ahead/behind chips; staged / unstaged /
  untracked sections with per-file rows and +/- counts.
- **Actions**: create a worktree for a branch (`git worktree add`), point a pane's cwd at a
  worktree, stage/unstage/discard (discard confirms, always), open a file's diff, copy branch name.
- **The branch's pull request** is a row under the branch — number, title, and state in GitHub's
  own colours — that opens the PR in the browser. Read through `gh pr view --json`, because a PR
  number is a fact only the forge has; `gh` is located by path, since a bundled app inherits
  launchd's `PATH` rather than a login shell's. No `gh`, no auth, a non-GitHub remote and a branch
  with no PR are one case with one answer: no row. Asked at most once a minute and immediately on
  a branch change, because unlike everything else here it crosses the network.
- **Refresh**: on FSEvents change under `.git/` plus a 5s floor, not a busy poll.
- **Destructive operations are explicit.** No auto-stash, no auto-commit, no implicit branch
  switching. The tile reports state and performs only what the user clicks.

## 5. Context

The drop target. Files, folders, and links that the agent should know about.

- **Accepts**: `NSPasteboard.PasteboardType.fileURL`, `.URL`, `.string`, and drags from Finder,
  the Files tile, a browser, or another app.
- **Persistence**: security-scoped bookmarks so a dropped folder outside the project is still
  readable after relaunch. Stale bookmarks are shown as such with a re-grant action.
- **Each item is a card**, rounded and bordered like the chat's changed-files table, and
  every card the same height: a thumbnail, the name, and a caption — the kind as a badge
  (`MD`, `SWIFT`, `Folder`), a folder's file count, the size in Finder's units, and a token
  estimate (bytes/4 heuristic to start; swap in a real tokenizer later without changing
  the UI). One walk of a folder measures all three. The thumbnail is QuickLook's — the
  file's own icon until it arrives, or for good when QuickLook has nothing for the type —
  generated off the main actor so a list of PDFs does not stall the pane. A missing item's
  caption says only `missing`: its size and tokens are stale facts about a file that is
  not there.
- **Send to shell** — the reason the tile exists. Injects `@<path relative to project root>`
  references into the focused shell **without submitting**, so the user types their sentence
  around them. Multi-select joins with spaces. Absolute paths are used when the target is
  outside the project. The footer sends the whole list; **each row sends just itself**, in the
  same `@path` form — a list gathered over a session usually holds more than the one file the
  next prompt is about. A missing file's send is dimmed.
- **Also**: "Copy as prompt" (paths plus a short preamble), pin/unpin, remove, reveal in Finder.
  Remove is a **minus**, not a trash can: it takes a row off a list and never touches the file.
- Stored per project alongside the layout.

## 6. Ports

Listening TCP ports, and which pane owns them.

- **Source**: `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` — field output, not columnar, because command
  names contain spaces. Unprivileged `lsof` reports the current user's processes, which is what
  we want.
- **Poll**: 3s, paused when occluded.
- **Columns**: port, process, pid, bind address. A port whose pid descends from a pane's shell is
  badged with that pane — "your dev server is in pane 2" is the useful fact.
- **Actions**: open `http://localhost:<port>`, copy the URL, reveal the owning pane, and kill
  (SIGTERM, then SIGKILL after 3s, with a confirmation).

---

## 7. Chat

A conversation with a model, beside the terminal. Five providers behind one protocol
(`UltraChat.ChatProvider`): Apple's on-device model through Foundation Models, which needs
no key and is the default; the two engines, Claude Code and Codex, which run the user's
subscription (below); Anthropic; and OpenRouter, many vendors' models behind one key — an
API key is the whole of its setup. The pane's menu and Settings group them by how they are
paid for (`ChatProviderID.Group`: on this Mac, subscription, API key), since that is the
choice made first. OpenRouter speaks OpenAI's chat API, so it is served by the OpenAI
provider type at its own base URL. OpenAI and Gemini were each offered with their own key
and are retired: OpenRouter reaches their models and everyone else's with the one key, so
a second key-and-vendor row bought nothing. Their cases stay in `ChatProviderID` so a
conversation saved on either still opens; nothing offers them, and a default left pointing
at one falls back to Apple. A local server (Ollama, LM Studio) was once offered too, "OpenAI-compatible", and was
dropped: a base URL, an optional key and a model name that had to be typed was more setup
than it was worth. Each is raw HTTP over `URLSession.bytes` with a small SSE parser — no
SDK, because none of the services ships a Swift one and the community packages lag the
APIs. Every provider is tested against a recorded transcript.

- Conversations are files: `.ultra/chats/<id>.json`, beside the todo and context lists,
  newest first in the pane's clock menu. A conversation carries its own provider and model.
- The store (`ChatStore`) is owned by the tile factory, like an editor's tabs, so an answer
  still streaming survives the pane being rebuilt. The pane's record carries the
  conversation id in `command`, the way an editor's carries its file.
- The answer is rendered in blocks (`MarkdownBlocks`): paragraphs through Foundation's
  Markdown parser; lists drawn with bullets or their numbers in a column, nesting stepped
  in; a heading as its own line; fenced code in a box whose Copy and "type at the prompt"
  float over the header on the same glass pill as a row's hover controls — the latter is
  `injectIntoShell`, the same verb every other tile sends with. The prompt asks the model
  for plain prose — no headings, nothing bold, backticks for names — and a bulleted list
  whenever there are several things to say.
- The model can read the project. Every request carries a `ChatToolbox` — `ProjectFiles`:
  `list_files`, `find_files`, `read_file`, `search_files` — and each provider runs its own
  tool loop, because only it knows its service's shape for a call and a result; within a
  loop a turn goes back exactly as it arrived (Claude's thinking blocks and signatures,
  Gemini's `thoughtSignature`). Apple's session runs the loop itself through a bridged
  `Tool`, with results cut short for its small context. READ-ONLY, and confined to the
  project root (`..`, absolute paths and symlinks out of it are refused): a chat that writes
  needs a diff to approve and an undo, and the agents in the panes beside it do that job.
  Listing and searching follow git's ignore rules; a file named outright can be read
  whether git ignores it or not. Long files come a page at a time.
- Tool calls are stored on the assistant's message (`ChatMessage.toolCalls`, with results),
  one message per round, so a conversation replays to the service as it happened. The pane
  shows each as a quiet row — "Read Package.swift" — above the answer it led to.
- Keys live in the keychain (`ChatCredentials`); Settings ▸ Chat is where they go in.
- Two more providers are ENGINES rather than services: the user's Claude or ChatGPT plan,
  through the vendor's own agent on this Mac (`ChatEngine`). This is the only way a
  subscription can be used from another app — Anthropic's terms allow a Claude plan only
  inside the unmodified Claude Code binary, signed in through Anthropic's own flow, and
  OpenAI opens a ChatGPT plan to third parties only through Codex — so nothing in Ultra
  holds a token, and sign-in is the engine's own; Xcode and Notepad.exe reach the plans the
  same way. `ClaudeCodeProvider` runs one `claude -p` per turn, speaking stream-json, with
  its own tools and edits accepted without a prompt (`acceptEdits`: nobody is at a prompt
  to answer one; a command follows the user's own Claude Code rules); `CodexProvider`
  talks JSON-RPC to one `codex app-server` kept for the whole app (`CodexEngine`), sandbox
  `workspace-write`, approvals off. So, unlike the API providers with our read-only tools,
  a chat on an engine CAN change the project — it is the agent the user would run in the
  pane beside, in a chat — and every read, search and command is a row above the answer,
  while the changes become one table of the files they touched (`ChangedFilesTable`): a
  bordered, rounded table with a row of one height per file — name, folder from the
  project down, `+12 −3` — which opens the file in the editor. One file is the same table,
  so a single change does not look like a different thing from two; and one ANSWER is one
  table, drawn under its last turn with every turn's changes added up, since a turn that
  calls tools is followed by another and the files all of them touched are one answer's.
  A file added or deleted is a row of the same table as one edited (`ChatFileChange.kind`):
  a new file has a plus on its doc and `+N`, a deleted one a struck name, `−N` and nothing
  to open. The counts ride on the call (`ChatToolCall.changes`): a Claude Code edit is
  counted from the old and new text in its arguments, a Write against the file on disk if
  it is there (and is an add if not — the result settles it: "File created successfully"),
  a Codex change from the unified diff it reports on completing, with the kind Codex
  names. A command is read for the files it plainly removes or makes — `rm`, `git rm`,
  `mv`, `touch` (`CommandChanges`), counted from disk before it runs — and anything else a
  command does to files is not guessed at. An edit or command that failed counts as
  nothing and stays a plain row. In the
  pane's menu each engine is a submenu of its models, so plan and model are one pick.
  Both keep the conversation themselves — the first turn starts a session or thread, saved
  as `ChatConversation.engineSession`, and every later turn resumes it — so the history is
  never sent twice; an engine that has lost it is started again and told the transcript.
  A model named `default` means the engine's own. The binaries are looked for in the usual
  homes of a developer's tools and then asked of the login shell, since a GUI app's PATH
  is the bare one. Settings ▸ Chat shows who is signed in to each (`claude auth status`,
  `account/read`), starts the sign-in, and offers the install command when the binary is
  missing. A sign-in is a session with states the row shows as they happen
  (`EngineSignIn`: the page is open, approve it there; checking; signed in, just now), with
  the page's link to open again, a Cancel, a ten-minute limit and, for Claude Code, a field
  for the code its login falls back to when the browser cannot reach its callback.
  Completion is checked, not believed: Claude Code's keychain entry is watched for the
  write its login makes, Codex's completion notification is waited for, and the account is
  read back before the row says signed in. Both are tested against recorded lines of their
  protocols.
- Commands: Pane ▸ Chat ▸ New Chat (⌥⌘N) and Stop Response (⌘.), both on the focused pane.
  Escape also stops. While an answer is on its way the composer's send slot holds the
  thinking star (`ThinkingStopButton` around `ThinkingStar`, the design's own four-pointed
  shape): it turns half a revolution, easing to a stop, rests a beat and goes again, so it
  reads as working in strokes rather than as a loading wheel. It zooms in from small when
  the answer starts and shrinks away when it is in; under Reduce Motion it breathes in
  opacity and does not turn. Under the pointer it is the stop button — the whole slot is
  the button, so a click on the star stops too. File ▸ New Tile Pane ▸ Chat is ⌥⌘C.
- Each pane can show its chat light: the sun in the footer, or Pane ▸ Chat ▸ Toggle Light
  Chat (⌃⌘L — the browser's key for the same thing; the two share it, and the menu fires
  whichever is enabled). It works the way a browser pane's page mode does: the choice is
  saved as `PaneRecord.appearance`, which the canvas reads to paint the pane's surface,
  header and glass, so the transcript sits on solid white rather than light glass gone
  grey. It is the pane's, not the conversation's — the same thread opened in another pane
  keeps that pane's look. Off, the default, records nil and follows the app.

## 8. Browser

One web page in a pane, for what a developer keeps beside a shell: the dev server, the docs,
the PR. Not a browser app. There is no search, no tabs and no bookmarks, and a second page
goes in a second pane.

- The address field takes a URL or something close to one (`BrowserAddress`, pure and
  tested). A local address gets HTTP (`localhost:3000`, `127.0.0.1`, `*.local`, the private
  LAN ranges) because a dev server rarely speaks TLS. Anything else that looks like a host
  gets HTTPS, and a path is a file. Text that is not an address is refused, not searched
  for: in a terminal app it is as likely to be a path or a secret as a query.
- The page lives in a `BrowserSession`, owned by the tile factory like an editor's tabs.
  A rebuilt pane gets the same `WKWebView` back, scrolled where it was, instead of a reload.
  The web view is made the first time the pane is shown, not when a workspace is restored.
- The record keeps the URL in `command`, the page title as the pane's title and the host
  as its subtitle, so a restored workspace reopens the page.
- Everything goes in the shared, persistent website data store, so a dev server login
  survives a relaunch. Right-click ▸ Inspect Element works (`isInspectable`), and so does
  the wrench in the footer (⌥⌘I), through WebKit's private `_inspector` since there is no
  public call. Empty Caches (the circular arrows) removes the disk, memory and fetch caches
  and reloads from the network. Cookies, local storage and IndexedDB stay, so logins survive.
- Each pane can show its page light or dark: the moon in the footer, or Pane ▸ Browser ▸
  Toggle Dark Page (⌃⌘L). The mode is the PANE's, not only the page's: it is saved as
  `PaneRecord.appearance`, which the canvas reads to paint the pane's surface, header and
  glass light or dark, so a white page does not sit in a dark pane like a hole. A light pane
  is solid white rather than light glass, which a dark window tints grey. Any pane can
  pin its look this way; nil, the default, follows the app. Dark sets
  the web view's appearance dark, so a page with its own dark theme (`prefers-color-scheme`)
  uses it. A page without one, which is most dev servers, is inverted by an injected style,
  with its images and video inverted back. Light pins the page light, whatever the app is.
- `target="_blank"` and `window.open` load in the same pane: a pane has no second window.
- A failed load shows in the pane's toast, with the dev-server case put in words: "Nothing is
  answering at localhost:5173 — is the server running?" and a Retry.
- `NSAllowsArbitraryLoadsInWebContent` is set, so plain-HTTP servers on the LAN load. No
  entitlement is needed: WebContent runs in WebKit's own processes.
- Commands: Pane ▸ Browser ▸ Open Location (⌘L), Reload Page (⌘R), Back (⌘[), Forward (⌘]),
  Show Web Inspector (⌥⌘I), Empty Caches, Open in Default Browser. They act on the focused browser pane, or the first one in the
  layout. Open Location opens a browser pane when there is none. File ▸ New Tile Pane ▸
  Browser is ⌥⌘B. In the address field, Return loads the page and gives it the keyboard,
  and Escape puts the address back.
- The agent's `browse` verb — `{"verb":"browse","url":"localhost:3000"}` on the control
  socket — shows a page the same way, through the address field's own rules, so the dev
  server an agent just started lands beside it without a click. `file:` and custom schemes
  are refused: a process that cannot see the screen does not get to open them.
- Ports rows open a server in a browser pane, reusing the one already open (the globe
  button), or in the default browser (Safari's compass).

## 9. Simulator

An Apple simulator in a pane, live: the screen, the pointer as a finger, the keyboard as
the device's keyboard. For the app the agent just built — one device per pane, and a second
device is a second pane. Not the Simulator app, which Xcode 27 no longer ships anyway.

- **Two paths to the device, on purpose.** Listing, booting, shutting down, appearance,
  URLs and the fallback screenshot go through `xcrun simctl` (`SimulatorControl`), which is
  Apple's supported surface. The screen and touches go through Xcode's private CoreSimulator
  and SimulatorKit (`SimulatorFrameworks`), because nothing else can do them: `simctl` has no
  touch verb, and there is no window to mirror.
- **The private path is loaded, never linked.** Both frameworks are `dlopen`ed by path, every
  class is looked up by name and every selector checked with `responds(to:)`. They are
  Apple-signed, which the hardened runtime's library validation permits, so no entitlement is
  added. A machine without Xcode, or an Xcode that moves a class, gets a pane that still boots,
  lists and screenshots and says why it is not live. Xcode's own Previews and Meta's idb drive
  devices through the same classes.
- **The screen is the device's framebuffer.** The device's `SimDisplayIOSurfaceRenderable`
  port for its BUILT-IN screen — an iPad also has a TV-out one, so the port is picked by its
  `screenType`, not by its place in the list — hands over the `IOSurface` its compositor
  renders into; `SimulatorDisplayView` sets it
  as a layer's contents and re-sets it on every damage callback. No copy, no permission
  prompt, and it works for a device booted with no window at all. Rotation is a layer
  transform on the port's `displayAngle`.
- **Touches, keys and buttons are Indigo messages** built by SimulatorKit's exported C
  functions and sent through `SimDeviceLegacyHIDClient`. A click is a finger: down, dragged,
  up, as ratios of the screen. Keys go through `IndigoHIDMessageForKeyboardNSEvent`, which
  maps the Mac key code with Simulator's own table; modifiers arrive as `flagsChanged` and go
  by HID usage; auto-repeats are left to the device, and whatever is held is lifted when the
  screen loses the keyboard. Home and Lock are hardware buttons, held for 100ms.
- **Two generations of the wire format, told apart at run time.** Xcode 27's SimulatorKit
  grew the payload from 0x90 to 0xA0 bytes, builds the whole single-touch message itself
  (with a real "moved" phase, throttled to one per 16ms), and takes EVERY message on the
  screen's HID service, 0x32 — buttons included, where idb sends 0x33, and keys, whose
  builder still writes 0x64. The guest drops anything else without an error: a click, Home
  and typing all did nothing until this was found. Older SimulatorKit emits a multi-touch
  message that is re-enveloped the way idb does. `SimulatorInput` reads which it is talking
  to off the header of what the builder returns — never from an Xcode version number.
- **Gestures from the bottom edge.** iOS reads a swipe up as Home, the app switcher or unlock
  only when the touch says it began at the bottom edge — SimulatorKit's `IndigoHIDEdge`,
  which the touch builder turns into digitizer flags. A drag that starts within 12pt of the
  screen's bottom as the person sees it, or on the band just below it, carries that edge
  for its whole length (`SimulatorInput.Edge`). Swipes from the top and the left need no
  flag: the system and UIKit read them from the position, whatever the edge says.
- **What the device drops.** The first message a process sends is ignored, so a new
  connection sends one that changes nothing (the right Option key let go) before any
  touch, then lets go of Home and Lock — every device chosen, booted or reconnected starts
  with no button held by whoever used it last. There is no Siri button: idb's Siri source
  sent to an Xcode 27 device brings its home screen down until SpringBoard restarts. A hardware button held down swallows every later press, touch and key, so a
  press builds its lift first and always sends it — `pressAndRelease` for a caller about
  to exit, `releaseAll` when a pane lets go mid-press.
- **Corners.** Each device type names a framebuffer mask in its profile — the PDF Simulator
  clips the screen with — and the pane clips the live screen to it, every device its own
  radius (`DeviceChrome.cornerMask`). The drawn enclosure is off for now
  (`SimulatorSession.showsEnclosure`); the corners do not depend on it.
- **Zoom.** The device is drawn at a multiple of the size that fits the pane — 25% to 400%,
  Fit being 100% — through Pane ▸ Simulator ▸ Zoom In on Device (⌃⌘=), Zoom Out on Device
  (⌃⌘-) and Fit Device to Pane (⌃⌘0), the same three in the footer, or a pinch. ⌃⌘ because
  ⌘= is Equalize Panes and ⌘0–9 pick panes. A device larger than the pane is panned with
  two fingers, only as far as its edges; touches follow the zoom. The footer shows the
  level once it is not Fit, and the zoom is saved in the pane's `tileState`
  (`SimulatorPaneState`), so a restored workspace shows the device the same size.
- Scrolling with a trackpad is not passed on: SimulatorKit itself routes the scroll wheel
  only to a watch's Digital Crown. On iOS a list scrolls by dragging, as in Simulator.
- **`SimulatorSession`** is owned by the tile factory like a browser's page: the device, its
  state, the display connection and the touch client survive a pane rebuild. It polls the
  device list every two seconds while the pane is showing (`TilePolling`), and connects to
  the screen when its device is booted.
- The record keeps the device's UDID in `command`, its name as the pane's title and its
  runtime as the subtitle, so a restored workspace reopens on the same device — and says so
  when that device has since been deleted.
- **Screenshot** writes a PNG to the project's `.ultra/screenshots/` and types its path at
  the shell's prompt: what is on screen, in front of the agent, in one press.
- Commands: Pane ▸ Simulator ▸ Home (⇧⌘H), Lock, Boot Device, Shut Down Device, Take
  Screenshot, Toggle Dark Appearance. The footer adds Open URL on Device…. File ▸ New Tile
  Pane ▸ Simulator is ⌥⌘P. A focused pane on a live device gives the keyboard to the screen.
- **The agent's verb.** `{"verb":"simulator","device":"iPhone 17","app":"com.example.App"}`
  on the control socket shows that device — the pane already on it, else the focused
  simulator pane, else a new one — boots it if it is shut down, and launches the app once it
  is up. The device is a name or a UDID; a name prefers a booted device, and a device whose
  runtime is gone is refused by name. The agent installs with `simctl` in its own shell; the
  verb only puts the device on screen. The reply says what happened: an unknown device, no
  room for a pane, or — on a device that was already up — the launch's own error, such as an
  app that is not installed. A device that has to boot first launches the app when it is up,
  and a failure then is the pane's toast's to show.
- **A device booting in the pane.** It connects as soon as `simctl` says Booted, which can
  be before the device has a framebuffer: the pane then shows a screenshot of the boot
  screen, input off, until the first surface arrives. The view is re-pointed whenever it is
  not showing the live surface — not only when the picture's size changes, since the
  screenshot is exactly the framebuffer's size — the screenshot is dropped once the screen
  is live, and each poll re-reads the surfaces of a pane still not showing them.
- **The socket never holds the window.** The channel's handler runs as a main-actor task and
  awaits: listing devices is a subprocess, and a cold CoreSimulator can take seconds. The
  serving queue waits for the reply (up to a minute); the main thread keeps drawing.
- **Live tests.** `ULTRA_SIM_LIVE=1 swift test --filter SimulatorLiveTests` runs the
  private-API bridge against whatever device is booted (`ULTRA_SIM_UDID` picks one), on
  Settings and the home screen, checking what `simctl io screenshot` shows afterwards: the
  built-in screen is the one shown, Home leaves an app, a swipe up from the bottom edge does
  too, a tap selects a row, a drag opens Spotlight and typing searches Settings. Off by
  default, since it touches a real device. A new Xcode that changes the wire format fails
  here first.

## Sandboxing consequence

Spawning PTYs and shelling out to `lsof`, `ps`, and `git` are all incompatible with the App
Sandbox. Ultra ships **outside the Mac App Store**: Developer ID signed, hardened runtime,
notarized and stapled — the same pipeline documented in the Electron app's `AGENTS.md`. This is a
deliberate distribution decision, not an oversight, and it is why security-scoped bookmarks are
still used in the Context tile (they are about restoring user intent across launches, not the
sandbox).

## Notices

What a tile has to say about its file — reloaded, changed underneath an edit, could not be
saved, a page that would not load — is a **toast**: a regular-glass rounded rectangle — 12pt corners, not a capsule, which at
that height reads as a pill button — floating over the
foot of the content, 4pt above the footer and 4pt in from the pane's sides, with a filled
symbol, the sentence, any verb it offers (Reload, Retry) and an `⌫`-shaped close control.
`TileToast` draws it; `TileNotice` holds the words, once, so the Editor and the Todo list
cannot say "reloaded" two different ways.

It was a strip across the top of the tile. A strip takes a row, so every reload pushed the
text being edited down a line and pulled it back up on close — a notice about the file must
not move the file. A toast covers a corner of the content instead, which is the exception
the design language makes to "no steady-state intersections" (docs/02) — shared with the
Todo list's progress bar (§ 2), which floats in the same place; the toast stacks above it: an
informational toast (reloaded) leaves on its own after four seconds, pausing while the
pointer is on it; one that needs a decision (a conflict) or reports a failure stays until
closed. The tone is in the symbol's colour alone — the toast is never tinted.

Close is also **Pane ▸ Dismiss Notice** in the menu and the palette, enabled only while the
focused pane shows a toast, so a notice can be put away without the pointer.

| Tile | Notices |
|---|---|
| Editor | reloaded · conflict (+ Reload) · failed |
| Todo | reloaded · could not save |
| Browser | load failed (+ Retry) |
| Simulator | failed |

## Adding a tile later

A new tile is: conform to `Tile`, register a `TileKind`, add a case to the pane-descriptor
decoder with a migration, add a menu item. **It touches no engine code.** If a tile ever needs a
change in `UltraLayout`, that is a signal the abstraction leaked — fix the boundary, not the tile.
