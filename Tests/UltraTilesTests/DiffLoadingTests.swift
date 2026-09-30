import Testing
import AppKit
import SwiftUI
import Foundation
@testable import UltraTiles

/// A diff in the editor is fetched by the view showing it, so what is covered here is the
/// view: every diff that is put on screen has to be asked for. One that is not sits on
/// "Loading…" for as long as it is looked at.
@Suite("Diffs load when they are shown")
@MainActor
struct DiffLoadingTests {

    /// Not a repository, which is fine: git prints nothing, and nothing parses to an empty
    /// diff. Loaded-and-empty is all these need to tell apart from never-asked-for.
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ultra-diff-loading-\(UUID().uuidString)")

    private func diff(_ path: String) -> EditorRequest {
        .diff(DiffRequest(repositoryRoot: root,
                          change: GitModel.Change(path: path, staged: .unmodified,
                                                  unstaged: .modified),
                          sides: [.unstaged]))
    }

    private func session(_ item: EditorSession) throws -> DiffSession {
        guard case .diff(let session) = item.content else {
            throw DiffLoadingError.notADiff
        }
        return session
    }

    private enum DiffLoadingError: Error { case notADiff }

    /// An editor pane in a window, which is what it takes for a view's task to run.
    private func mount(_ sessions: EditorSessions) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: EditorTile(context: .inert(root: root),
                                                                sessions: sessions))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Give the view's task turns of the main actor until `condition` holds, or give up.
    private func settle(in window: NSWindow, until condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The second changed file clicked in a Git pane. The pane was already showing a diff,
    /// on the same side, so nothing about the view changed except which diff it was handed.
    @Test("a diff opened over another diff is loaded too")
    func secondDiffLoads() async throws {
        let sessions = EditorSessions()
        let window = mount(sessions)

        let first = try session(sessions.open(diff("Sources/a.swift")))
        try await settle(in: window) { first.diff != nil }
        #expect(first.diff != nil)

        let second = try session(sessions.open(diff(".ultra/todo.md")))
        try await settle(in: window) { second.diff != nil }
        #expect(second.diff != nil, "the pane must not sit on Loading… for the second diff")
        #expect(!second.isStale)
    }

    /// Clicking the row of the diff that is ALREADY showing, after the file changed: the
    /// view is the same view on the same session, and it still has to fetch again.
    @Test("a diff on screen that is marked stale is fetched again")
    func staleDiffOnScreenReloads() async throws {
        let sessions = EditorSessions()
        let window = mount(sessions)

        let shown = try session(sessions.open(diff(".ultra/todo.md")))
        try await settle(in: window) { !shown.isStale }
        #expect(!shown.isStale)

        sessions.open(diff(".ultra/todo.md"))
        #expect(shown.isStale)
        try await settle(in: window) { !shown.isStale }
        #expect(!shown.isStale, "a stale diff that is on screen must be reloaded")
    }
}
