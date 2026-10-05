import Foundation

/// The pages one browser pane is holding, and which of them is showing.
///
/// A pane started as one page, on the reasoning that a second page is a second pane. That
/// holds for the dev server beside its docs; it does not hold for the docs themselves,
/// where following three links meant three panes on a canvas with room for none, or losing
/// the page you came from. So a pane holds a row of pages, like an editor's files.
///
/// Owned by `TileFactory` for the editor's reason: a pane is rebuilt whenever it is restored
/// or converted, and tabs living in the view would take every page with them.
///
/// Never empty. A browser pane with no tab is a pane with nowhere to type an address, so
/// the last tab cannot be closed — ⌘W closes the pane, which is what that would have meant.
@MainActor
@Observable
public final class BrowserTabs {
    public private(set) var sessions: [BrowserSession]
    public private(set) var selectedID: BrowserSession.ID

    /// Something a restore would need changed: a page, a title, the mode, the tabs
    /// themselves or which one is showing. The pane's header and its saved record follow.
    @ObservationIgnored public var onChange: (() -> Void)?

    /// - Parameters:
    ///   - urls: one entry per tab, nil for an empty one. An empty list is one empty tab.
    ///   - selected: the index of the tab showing, clamped into the list.
    public init(urls: [URL?] = [nil], selected: Int = 0, isDark: Bool = false) {
        let urls = urls.isEmpty ? [nil] : urls
        let sessions = urls.map { BrowserSession(url: $0, isDark: isDark) }
        self.sessions = sessions
        self.selectedID = sessions[min(max(selected, 0), sessions.count - 1)].id
        sessions.forEach(adopt)
    }

    /// One tab, on a page that already exists. For previews, which load their page first.
    public init(_ session: BrowserSession) {
        sessions = [session]
        selectedID = session.id
        adopt(session)
    }

    /// The tab that is showing. There always is one.
    public var selected: BrowserSession {
        sessions.first { $0.id == selectedID } ?? sessions[0]
    }

    /// Whether the pane shows its pages dark. The PANE's, not a tab's: the canvas paints
    /// the whole pane to match, and a pane that changed colour with every tab switch would
    /// be a strobe. See `BrowserSession.isDark`.
    public var isDark: Bool { selected.isDark }

    public var canClose: Bool { sessions.count > 1 }

    // MARK: - Verbs

    /// Another tab, after the last one. Empty unless a URL is given — a link that asked for
    /// a window of its own, which is what a tab is here.
    @discardableResult
    public func newTab(url: URL? = nil) -> BrowserSession {
        let session = BrowserSession(url: url, isDark: isDark)
        adopt(session)
        sessions.append(session)
        selectedID = session.id
        onChange?()
        return session
    }

    public func select(_ id: BrowserSession.ID) {
        guard selectedID != id, sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        onChange?()
    }

    /// Close one and land on the tab before it — the editor's rule, so the two rows of tabs
    /// in this app behave as one. The last tab stays: see the type's note.
    public func close(_ id: BrowserSession.ID) {
        guard canClose, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        if selectedID == id { selectedID = sessions[max(0, index - 1)].id }
        session.onChange = nil
        session.openInNewTab = nil
        session.close()
        onChange?()
    }

    public func closeSelected() { close(selectedID) }

    /// Wraps, as the editor's tabs and the window's sessions do.
    public func selectNext() { step(by: 1) }
    public func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        select(sessions[(current + offset + sessions.count) % sessions.count].id)
    }

    /// The pane is closing: every page stops, the ones behind the selected tab included.
    public func closeAll() {
        onChange = nil
        for session in sessions {
            session.onChange = nil
            session.openInNewTab = nil
            session.close()
        }
    }

    // MARK: - Persistence

    /// What a restore needs beyond the selected page, which the record's `command` already
    /// carries: the other tabs and their order.
    public var state: BrowserPaneState {
        BrowserPaneState(tabs: sessions.map { $0.requestedURL?.absoluteString },
                         selected: sessions.firstIndex { $0.id == selectedID } ?? 0)
    }

    // MARK: - Plumbing

    private func adopt(_ session: BrowserSession) {
        session.onChange = { [weak self, weak session] _, _ in
            guard let self, let session else { return }
            self.note(session)
        }
        session.openInNewTab = { [weak self] url in _ = self?.newTab(url: url) }
    }

    /// A tab's page, title or mode changed. The mode is carried to the other tabs — each
    /// reports back through here, finds nothing left to carry, and stops.
    private func note(_ session: BrowserSession) {
        for other in sessions where other !== session && other.isDark != session.isDark {
            other.setDark(session.isDark)
        }
        onChange?()
    }
}

/// A browser pane's own saved state, in its record's `tileState`.
public struct BrowserPaneState: Codable, Equatable, Sendable {
    /// Each tab's page, in order. Nil for a tab with nothing loaded.
    public var tabs: [String?]
    public var selected: Int

    public init(tabs: [String?], selected: Int = 0) {
        self.tabs = tabs
        self.selected = selected
    }

    /// Nil for a single tab, so a pane that never had a second one saves no state at all
    /// and its record is what it was before panes had tabs.
    public var encoded: Data? {
        guard tabs.count > 1 else { return nil }
        let encoder = JSONEncoder()
        // Sorted, so the same tabs are the same bytes: a record is compared before it is
        // saved, and a key order that wandered would be a write on every page title.
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    /// The state in `data`, or nil when there is none or it does not read — the pane then
    /// restores as the one page its record names.
    public static func decode(_ data: Data?) -> BrowserPaneState? {
        guard let state = data.flatMap({ try? JSONDecoder().decode(BrowserPaneState.self, from: $0) }),
              !state.tabs.isEmpty else { return nil }
        return state
    }
}
