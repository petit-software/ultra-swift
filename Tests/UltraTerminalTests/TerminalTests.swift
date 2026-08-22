import Testing
import Foundation
import SwiftUI
@testable import UltraTerminal
@testable import UltraDesign

@Suite("PTY resize coalescing")
struct ResizeCoalescerTests {

    @Test("a size that does not cross a cell boundary produces no PTY traffic")
    func unchangedGridIsSilent() {
        var coalescer = ResizeCoalescer()
        let sent1 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 0)
        #expect(sent1)
        let sent2 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 10)
        #expect(!sent2)
        let sent3 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 20, isFinal: true)
        #expect(!sent3)
    }

    @Test("during a drag, at most one resize per interval")
    func throttledDuringDrag() {
        var coalescer = ResizeCoalescer(minimumInterval: 0.033)
        let sent4 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 0)
        #expect(sent4)
        // A 120Hz drag: ~8ms apart. Only the ones past the interval get through.
        let sent5 = coalescer.shouldSend(.init(cols: 81, rows: 24), at: 0.008)
        #expect(!sent5)
        let sent6 = coalescer.shouldSend(.init(cols: 82, rows: 24), at: 0.016)
        #expect(!sent6)
        let sent7 = coalescer.shouldSend(.init(cols: 83, rows: 24), at: 0.024)
        #expect(!sent7)
        let sent8 = coalescer.shouldSend(.init(cols: 84, rows: 24), at: 0.034)
        #expect(sent8)
    }

    @Test("the final resize always goes through, so the shell is never left stale")
    func finalAlwaysSends() {
        var coalescer = ResizeCoalescer(minimumInterval: 0.033)
        let sent9 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 0)
        #expect(sent9)
        // Well inside the throttle window, but authoritative.
        let sent10 = coalescer.shouldSend(.init(cols: 92, rows: 30), at: 0.001, isFinal: true)
        #expect(sent10)
        #expect(coalescer.lastSentGrid == .init(cols: 92, rows: 30))
    }

    @Test("a degenerate grid is never sent")
    func degenerateGrid() {
        var coalescer = ResizeCoalescer()
        let sent11 = coalescer.shouldSend(.init(cols: 0, rows: 24), at: 0)
        #expect(!sent11)
        let sent12 = coalescer.shouldSend(.init(cols: 80, rows: 0), at: 1, isFinal: true)
        #expect(!sent12)
    }

    @Test("a whole simulated drag sends far fewer resizes than it has frames")
    func dragIsQuiet() {
        var coalescer = ResizeCoalescer(minimumInterval: 0.033)
        var sent = 0
        // 1 second of 120Hz dragging, one column per frame.
        for frame in 0..<120 {
            if coalescer.shouldSend(.init(cols: 80 + frame, rows: 24),
                                    at: Double(frame) / 120) { sent += 1 }
        }
        #expect(sent <= 32, "\(sent) resizes for 120 frames is a SIGWINCH storm")
        #expect(sent >= 25, "throttling must not stall updates entirely")
    }

    @Test("reset forgets the last size, so a replaced process gets a fresh one")
    func reset() {
        var coalescer = ResizeCoalescer()
        let sent13 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 0)
        #expect(sent13)
        coalescer.reset()
        let sent14 = coalescer.shouldSend(.init(cols: 80, rows: 24), at: 0.001)
        #expect(sent14)
    }
}

@Suite("Shell launching")
struct ShellLauncherTests {

    @Test("a plain pane runs a login shell")
    func plainShell() {
        #expect(ShellLauncher.arguments() == ["-l"])
        #expect(ShellLauncher.arguments(runningAgent: "   ") == ["-l"])
    }

    @Test("an agent execs, so the pane's process IS the agent")
    func agentExecs() {
        #expect(ShellLauncher.arguments(runningAgent: "claude") == ["-l", "-c", "exec claude"])
        #expect(ShellLauncher.arguments(runningAgent: "codex --model o3")
                == ["-l", "-c", "exec codex --model o3"])
    }

    @Test("the login shell comes from the environment, with a sane fallback")
    func loginShell() {
        #expect(ShellLauncher.loginShell(environment: ["SHELL": "/opt/homebrew/bin/fish"])
                == "/opt/homebrew/bin/fish")
        #expect(ShellLauncher.loginShell(environment: [:]) == "/bin/zsh")
        #expect(ShellLauncher.loginShell(environment: ["SHELL": ""]) == "/bin/zsh")
    }

    @Test("availability probing finds a real binary and rejects a fake one")
    func availability() {
        #expect(ShellLauncher.isAvailable("ls"))
        #expect(!ShellLauncher.isAvailable("definitely-not-a-real-binary-xyzzy"))
        #expect(!ShellLauncher.isAvailable(""))
    }

    @Test("an agent's probe target is the first word of its command")
    func binaryExtraction() {
        #expect(AgentDefinition(name: "x", command: "codex --model o3").binary == "codex")
        #expect(AgentDefinition.builtIns.map(\.binary) == ["claude", "codex"])
    }

    @Test("a missing directory is refused, never silently swapped for $HOME")
    func directoryValidation() {
        #expect(ShellLauncher.validatedDirectory("/tmp") == "/tmp")
        #expect(ShellLauncher.validatedDirectory("/no/such/place/at/all") == nil)
        #expect(ShellLauncher.validatedDirectory("/etc/hosts") == nil, "a file is not a cwd")
        #expect(ShellLauncher.validatedDirectory(nil) == nil)
    }
}

@Suite("Theme bridging")
struct TerminalPaletteTests {

    @Test("themes carry a full 16-colour ANSI palette", arguments: [TerminalTheme.dark, .light])
    func paletteIsComplete(theme: TerminalTheme) {
        #expect(TerminalPalette.ansi(theme).count == 16)
    }

    @Test("colours survive the trip into SwiftTerm's 16-bit model")
    func roundTrip() {
        for theme in [TerminalTheme.dark, TerminalTheme.light] {
            for (index, colour) in theme.ansi.enumerated() {
                let source = TerminalPalette.sRGBComponents(colour)
                let converted = TerminalPalette.swiftTermColor(colour)
                #expect(abs(Double(converted.red) / 65535 - source.r) < 0.001,
                        "\(theme.name) ansi[\(index)] red drifted")
                #expect(abs(Double(converted.green) / 65535 - source.g) < 0.001)
                #expect(abs(Double(converted.blue) / 65535 - source.b) < 0.001)
            }
        }
    }

    @Test("terminal text clears 4.5:1 against its own background", arguments: [TerminalTheme.dark, .light])
    func contrast(theme: TerminalTheme) {
        func luminance(_ colour: SwiftUI.Color) -> Double {
            let c = TerminalPalette.sRGBComponents(colour)
            func channel(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let background = luminance(theme.background)
        let foreground = luminance(theme.foreground)
        let ratio = (max(background, foreground) + 0.05) / (min(background, foreground) + 0.05)
        #expect(ratio >= 4.5, "\(theme.name) foreground contrast is \(ratio), below WCAG AA")
    }
}

@Suite("OSC 7 working directory")
struct HostDirectoryTests {

    /// The exact string that caused every restored pane to announce "Working directory is
    /// gone" and fall back. The directory was fine; the value was a URL, not a path.
    @Test("a file URL from this machine becomes a path")
    func fileURLBecomesPath() {
        #expect(ShellLauncher.localPath(
            fromHostDirectory: "file://BakBook.local/Users/bigb/Repo/ultra-swift",
            hostName: "BakBook.local") == "/Users/bigb/Repo/ultra-swift")
    }

    @Test("host forms that all mean this machine")
    func hostVariants() {
        let path = "/Users/bigb/Repo"
        for raw in ["file:///Users/bigb/Repo",
                    "file://localhost/Users/bigb/Repo",
                    "file://BakBook/Users/bigb/Repo",
                    "file://bakbook.local/Users/bigb/Repo"] {
            #expect(ShellLauncher.localPath(fromHostDirectory: raw, hostName: "BakBook.local")
                    == path, "\(raw) should resolve to \(path)")
        }
    }

    /// The host says WHICH MACHINE the path is on. A shell ssh'd elsewhere reports a
    /// directory that does not exist here, and stripping it to a path would silently point
    /// at whatever happens to sit at that path locally.
    @Test("a directory on another machine is refused, not stripped")
    func remoteHostRefused() {
        #expect(ShellLauncher.localPath(fromHostDirectory: "file://build-server/var/www",
                                        hostName: "BakBook.local") == nil)
        #expect(ShellLauncher.localPath(fromHostDirectory: "file://192.168.1.20/srv",
                                        hostName: "BakBook.local") == nil)
    }

    @Test("a bare path is taken as-is, since some shells report one")
    func barePath() {
        #expect(ShellLauncher.localPath(fromHostDirectory: "/tmp/work") == "/tmp/work")
    }

    @Test("percent-encoding is decoded, so spaces survive")
    func percentEncoding() {
        #expect(ShellLauncher.localPath(
            fromHostDirectory: "file://BakBook/Users/bigb/My%20Projects/app",
            hostName: "BakBook") == "/Users/bigb/My Projects/app")
    }

    @Test("nothing usable yields nothing, rather than a bad path")
    func rejectsJunk() {
        for raw in [nil, "", "http://example.com/x", "not a url at all"] {
            #expect(ShellLauncher.localPath(fromHostDirectory: raw, hostName: "BakBook") == nil,
                    "\(raw ?? "nil") should be refused")
        }
    }

    @Test("the parsed path is one a shell could actually be started in")
    func resultIsAUsableDirectory() {
        let parsed = ShellLauncher.localPath(fromHostDirectory: "file://BakBook/tmp",
                                             hostName: "BakBook")
        #expect(parsed == "/tmp")
        // The whole point: the value now survives the check that was rejecting it.
        #expect(ShellLauncher.validatedDirectory(parsed) == "/tmp")
    }
}
