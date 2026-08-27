import AppKit
import Foundation

/// Rings the system alert for `BEL`, at most once every `minimumInterval`.
///
/// The rate limit is the whole point of the type. `NSSound.beep()` is not a cheap call: each
/// one asks CoreAudio for the default output device, opens a stream, plays a few hundred
/// milliseconds of alert, and tears the stream down again. One of those is fine. Hundreds a
/// minute is a system audio graph being connected and disconnected continuously, which is
/// audible as stutter in whatever else is playing and shows up in the audio daemon as a
/// constant churn of clients.
///
/// That rate is exactly what this app is for. An agent CLI uses `BEL` as a progress signal —
/// it rings on a tool call, on a permission prompt, on finishing a turn — so a pane running
/// one does not ring occasionally, it rings continuously, and a window of four agent panes
/// rings four times over. `Preferences.audibleBell` is off by default for that reason, and
/// this is what makes turning it ON a reasonable thing to do rather than a way to saturate
/// the audio device.
///
/// Coalescing is GLOBAL rather than per-pane, deliberately. Four agents finishing together is
/// one thing worth being told about, not four; and it is the total rate across every pane,
/// not any single pane's, that the audio device actually sees.
@MainActor
public enum TerminalBell {

    /// Half a second. Long enough that a burst collapses to one ring, short enough that two
    /// bells a person would experience as separate events still sound separate — the system
    /// alert itself is around a third of a second, so anything much below this would overlap
    /// its own tail anyway.
    public static let minimumInterval: TimeInterval = 0.5

    /// Monotonic, so the limiter cannot be defeated by the wall clock moving — `systemUptime`
    /// does not jump when the machine syncs its time or crosses a DST boundary.
    static var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Injectable so tests never actually make a noise.
    static var play: () -> Void = { NSSound.beep() }

    private static var lastRang: TimeInterval?

    /// Ring, unless one has already been rung too recently.
    ///
    /// Drops the extra bells rather than queuing them: a bell is a notification that
    /// something happened NOW, and one delivered late — after ten more have happened — is
    /// telling the user about the wrong event.
    public static func ring() {
        let time = now()
        if let lastRang, time - lastRang < minimumInterval { return }
        lastRang = time
        play()
    }

    static func resetForTesting() { lastRang = nil }
}
