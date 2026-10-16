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
- [ ] Commit, push main, GitHub release

## Notification permission

The settings footer says switching notifications on asks macOS for permission, but nothing
asked until the first notification was due, and that one was posted before the answer came
and refused. Ultra never appeared in System Settings ▸ Notifications.

- [x] Ask for permission when the toggle turns on, and at launch when it is already on
- [x] Post each notification from inside the authorization callback so the first is not dropped
- [x] Build and test
- [ ] Ultra 0.35.0: bump, commit, push, GitHub release
