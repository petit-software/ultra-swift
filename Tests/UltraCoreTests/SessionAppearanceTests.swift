import Foundation
import Testing
@testable import UltraCore

/// A session's icon is a preference ABOUT a project, kept the way a todo file's location is:
/// one defaults key per project, written through the moment it is chosen.
@Suite("Session appearance")
struct SessionAppearanceTests {

    /// Its own suite name per test, so one test's writes cannot be another's starting state.
    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @Test("a project that was never customised reads the default")
    func unsetReadsDefault() {
        let defaults = makeDefaults()
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/project",
                                                  defaults: defaults) == .default)
    }

    @Test("a choice survives being written and read back")
    func roundTrips() {
        let defaults = makeDefaults()
        let chosen = SessionAppearance(symbol: "flame.fill", tint: "orange")
        SessionAppearanceStore.set(chosen, forDirectory: "/tmp/project", defaults: defaults)
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/project",
                                                  defaults: defaults) == chosen)
    }

    /// The reason the key is canonical rather than the raw path: one project spelled three
    /// ways must not become three icons.
    @Test("spellings of one path share one icon")
    func canonicalKey() {
        let defaults = makeDefaults()
        SessionAppearanceStore.set(SessionAppearance(symbol: "leaf.fill", tint: "green"),
                                   forDirectory: "/tmp/project", defaults: defaults)
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/project/",
                                                  defaults: defaults).symbol == "leaf.fill")
    }

    @Test("two projects keep their own icons")
    func perProject() {
        let defaults = makeDefaults()
        SessionAppearanceStore.set(SessionAppearance(symbol: "leaf.fill", tint: "green"),
                                   forDirectory: "/tmp/a", defaults: defaults)
        SessionAppearanceStore.set(SessionAppearance(symbol: "flame.fill", tint: "red"),
                                   forDirectory: "/tmp/b", defaults: defaults)
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/a",
                                                  defaults: defaults).symbol == "leaf.fill")
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/b",
                                                  defaults: defaults).symbol == "flame.fill")
    }

    @Test("resetting goes back to the default and leaves no key behind")
    func resetClearsTheKey() {
        let defaults = makeDefaults()
        let directory = "/tmp/project"
        SessionAppearanceStore.set(SessionAppearance(symbol: "flame.fill", tint: "orange"),
                                   forDirectory: directory, defaults: defaults)
        SessionAppearanceStore.reset(forDirectory: directory, defaults: defaults)
        #expect(SessionAppearanceStore.appearance(forDirectory: directory,
                                                  defaults: defaults) == .default)
        // Storing the defaults must WRITE NOTHING — an absent key already means "default",
        // so a key holding one is a dead entry.
        #expect(defaults.data(forKey: SessionAppearanceStore.key(forDirectory: directory)) == nil)
    }

    /// A workspace old enough to have no directory cannot be filed under anything. It must
    /// read the default and swallow the write rather than crash or collide with another.
    @Test("a workspace with no project is not customisable")
    func noDirectory() {
        let defaults = makeDefaults()
        SessionAppearanceStore.set(SessionAppearance(symbol: "flame.fill", tint: "red"),
                                   forDirectory: nil, defaults: defaults)
        #expect(SessionAppearanceStore.appearance(forDirectory: nil, defaults: defaults)
                == .default)
    }

    /// Garbage under the key is a version that wrote a different shape, or a corrupted
    /// plist. The row must still draw.
    @Test("undecodable stored data falls back to the default")
    func corruptFallsBack() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8),
                     forKey: SessionAppearanceStore.key(forDirectory: "/tmp/project"))
        #expect(SessionAppearanceStore.appearance(forDirectory: "/tmp/project",
                                                  defaults: defaults) == .default)
    }
}
