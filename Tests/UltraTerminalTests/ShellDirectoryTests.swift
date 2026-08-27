import Testing
import Foundation
@testable import UltraCore
@testable import UltraLayout
@testable import UltraTerminal

/// A pane's header names the folder it is in, and for the whole life of this app it named
/// the folder the pane was OPENED in — a `cd` never moved it.
///
/// The cause was not in this app. OSC 7 is the escape a shell uses to report its directory,
/// and on a stock macOS the hook that emits it is sourced only when `$TERM_PROGRAM` is
/// `Apple_Terminal`, so zsh here reported nothing and there was nothing to follow. The fix
/// reads the directory from the kernel instead, which is why these tests use a real shell
/// and a real `cd`: a mocked one would have passed the whole time.
@Suite("Shell directory", .serialized)
@MainActor
struct ShellDirectoryTests {

    /// Poll without pumping the runloop — a main-actor test does not own one, and spinning
    /// it here deadlocks rather than waits.
    private func poll(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    private final class Recorder: ShellTerminalViewDelegate {
        var directories: [String?] = []
        func shellTitleChanged(_ view: ShellTerminalView, title: String) {}
        func shellDirectoryChanged(_ view: ShellTerminalView, directory: String?) {
            directories.append(directory)
        }
        func shellTerminated(_ view: ShellTerminalView, exitCode: Int32?) {}
    }

    /// `/usr/lib` rather than a temporary directory: `/tmp` and `/var` are symlinks on macOS
    /// and the kernel answers with the resolved path, which would make this test about
    /// symlink resolution instead of about following a `cd`.
    private let destination = "/usr/lib"

    @Test("a shell that cd's moves the pane with it")
    func followsCd() {
        let launched = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath().path
        let shell = ShellTerminalView(spec: ShellSpec(cwd: launched))
        let recorder = Recorder()
        shell.shellDelegate = recorder
        shell.start()
        defer { shell.stop() }
        #expect(shell.spec.cwd == launched)

        shell.inject("cd \(destination)", submit: true)
        // The shell needs to actually run the `cd`; the probe is driven by hand because the
        // debounce that normally drives it needs a runloop this test does not own.
        let moved = poll(upTo: 5) {
            shell.processID.flatMap { ForegroundProcess.workingDirectory(ofProcess: $0) }
                == destination
        }
        #expect(moved, "the shell never cd'd — the rest of this test proves nothing")
        shell.probeDirectory()

        #expect(shell.spec.cwd == destination)
        #expect(recorder.directories == [destination],
                "the header is told once, when the directory actually changed")
    }

    /// Probing is debounced against output, so it runs after every burst the shell produces
    /// — including the many that change nothing. Announcing those would repaint the header,
    /// the tab, and the persisted layout on every keystroke echo.
    ///
    /// `NSTemporaryDirectory()` is deliberately used UNRESOLVED here, because it is the case
    /// that actually broke: it is `/var/folders/…` while the kernel answers `/private/var/
    /// folders/…`, so a naive string comparison called a pane's first prompt a move and
    /// rewrote its header into a path the user never typed. Same directory, two spellings.
    @Test("a shell that has not moved says nothing, even where the path is spelled two ways")
    func silentWhenUnchanged() {
        let launched = NSTemporaryDirectory()
        let shell = ShellTerminalView(spec: ShellSpec(cwd: launched))
        let recorder = Recorder()
        shell.shellDelegate = recorder
        shell.start()
        defer { shell.stop() }

        // Waited for, not assumed. A forked child carries the PARENT's working directory
        // until the `chdir` immediately before its exec, so for a moment the kernel answers
        // this pid with the TEST RUNNER's cwd — and probing there reported a move to the
        // repository, then a second move back. Racy rather than wrong: it passed several
        // runs before it lost.
        //
        // Production cannot reach that window, which is the point. The probe is driven by
        // OUTPUT, and there is no output until the shell has exec'd and printed a prompt —
        // by which time the chdir is long done. Only a test calling `probeDirectory()` by
        // hand can get in early, so the test waits for the state production starts from.
        let settled = poll(upTo: 5) {
            shell.processID
                .flatMap { ForegroundProcess.workingDirectory(ofProcess: $0) }
                .map { WorkspaceDocument.canonical($0) == WorkspaceDocument.canonical(launched) }
                ?? false
        }
        #expect(settled, "the shell never reached its launch directory")

        for _ in 0..<5 { shell.probeDirectory() }
        #expect(recorder.directories.isEmpty)
        #expect(shell.spec.cwd == launched)
    }

    /// The probe outlives the process it probes: output arrives, the debounce is scheduled,
    /// and the shell exits before it fires. A dead pid must not resurrect a directory.
    @Test("a shell that has exited reports nothing")
    func silentAfterExit() {
        let shell = ShellTerminalView(spec: ShellSpec(cwd: NSTemporaryDirectory()))
        let recorder = Recorder()
        shell.shellDelegate = recorder
        shell.start()
        shell.stop()

        shell.probeDirectory()
        #expect(recorder.directories.isEmpty)
    }

    /// The pane header is built from the record, so following a `cd` is only useful if the
    /// record follows too — this is the seam between the shell and what the user reads.
    @Test("the pane record reports the new folder, abbreviated as a header shows it")
    func recordFollows() {
        let factory = ShellPaneFactory(defaultDirectory: NSTemporaryDirectory())
        let paneID = PaneID()
        _ = factory.makeContent(for: paneID)
        factory.startPendingShells()
        var records: [PaneRecord] = []
        factory.onDescriptorChange = { _, record in records.append(record) }
        defer { factory.release(paneID) }

        let shell = try! #require(factory.shells[paneID])
        shell.inject("cd \(destination)", submit: true)
        let moved = poll(upTo: 5) {
            shell.processID.flatMap { ForegroundProcess.workingDirectory(ofProcess: $0) }
                == destination
        }
        #expect(moved, "the shell never cd'd — the rest of this test proves nothing")
        shell.probeDirectory()

        #expect(records.last?.title == destination)
        #expect(records.last?.cwd == destination,
                "a pane restored later reopens where the user left it, not where it started")
    }
}
