import Testing
import Foundation
@testable import UltraTerminal

/// One `NSSound.beep()` is one CoreAudio stream opened and torn down. An agent rings `BEL`
/// on every tool call, prompt and finished turn, so the un-limited version of this is a
/// system audio graph being reconnected several times a second.
@Suite("Terminal bell", .serialized)
@MainActor
struct TerminalBellTests {

    /// Drives the limiter off a clock the test owns, so nothing here waits in real time and
    /// nothing here makes a noise.
    private func withBell(_ body: (_ advance: (TimeInterval) -> Void,
                                   _ rings: () -> Int) -> Void) {
        let clock = Clock()
        let previousNow = TerminalBell.now
        let previousPlay = TerminalBell.play
        defer {
            TerminalBell.now = previousNow
            TerminalBell.play = previousPlay
            TerminalBell.resetForTesting()
        }
        TerminalBell.resetForTesting()
        TerminalBell.now = { clock.time }
        TerminalBell.play = { clock.rings += 1 }
        body({ clock.time += $0 }, { clock.rings })
    }

    @MainActor private final class Clock {
        var time: TimeInterval = 1_000
        var rings = 0
    }

    @Test("a burst of bells is one ring, not one ring each")
    func burstCoalesces() {
        withBell { _, rings in
            for _ in 0..<200 { TerminalBell.ring() }
            #expect(rings() == 1, "200 bells in the same instant must open one audio stream")
        }
    }

    @Test("the first bell is never swallowed")
    func firstRingIsImmediate() {
        withBell { _, rings in
            TerminalBell.ring()
            #expect(rings() == 1)
        }
    }

    @Test("bells far enough apart both ring")
    func separateBellsBothRing() {
        withBell { advance, rings in
            TerminalBell.ring()
            advance(TerminalBell.minimumInterval)
            TerminalBell.ring()
            advance(TerminalBell.minimumInterval)
            TerminalBell.ring()
            #expect(rings() == 3, "a bell a second apart is a separate event")
        }
    }

    @Test("a bell just inside the window is dropped, not queued")
    func extraBellsAreDroppedRatherThanDeferred() {
        withBell { advance, rings in
            TerminalBell.ring()
            advance(TerminalBell.minimumInterval - 0.01)
            TerminalBell.ring()
            #expect(rings() == 1)

            // The dropped one must not come out later: a bell says something happened NOW,
            // and one delivered after ten more events describes the wrong event.
            advance(0.02)
            #expect(rings() == 1, "a dropped bell must not be queued")
        }
    }

    /// A window of four agent panes all ringing is one thing worth being told about, and it
    /// is the TOTAL rate across panes that the audio device sees.
    @Test("the limit is global, not one allowance per pane")
    func limitIsGlobalAcrossPanes() {
        withBell { advance, rings in
            for _ in 0..<4 { TerminalBell.ring() }   // four panes, same instant
            #expect(rings() == 1)
            advance(TerminalBell.minimumInterval)
            for _ in 0..<4 { TerminalBell.ring() }
            #expect(rings() == 2)
        }
    }
}
