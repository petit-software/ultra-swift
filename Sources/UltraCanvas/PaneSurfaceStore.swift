import AppKit
import SwiftUI
import UltraCore
import UltraDesign
import UltraLayout

/// A pane's content plus the metadata its chrome needs.
public struct PaneContent {
    public let view: NSView
    /// What this pane is, both for chrome and for persistence — one description, so a
    /// restored pane cannot disagree with the one on screen.
    public let record: PaneRecord

    public var descriptor: PaneDescriptor {
        PaneDescriptor(icon: record.icon, title: record.title, subtitle: record.subtitle)
    }

    public init(view: NSView, record: PaneRecord) {
        self.view = view
        self.record = record
    }
}

/// The single owner of pane views.
///
/// A surface is created once when a pane is created and released once when the pane is
/// closed. Splitting, resizing, closing a sibling, switching tabs, and restoring a window
/// are all frame assignments on views that already exist — **a pane's process outlives
/// every layout change**, which is the promise the whole architecture is built around.
///
/// It deliberately lives above the view layer, so even recreating the canvas view cannot
/// take a live PTY down with it.
@MainActor
public final class PaneSurfaceStore {
    private var containers: [PaneID: PaneContainerView] = [:]
    private(set) public var records: [PaneID: PaneRecord] = [:]
    /// Panes whose live surface is on loan to another store — see `lend`. While a pane is
    /// away this store shows a stand-in for it and the loan says where the pane went.
    private var loans: [PaneID: Loan] = [:]
    /// What this canvas shows in an away pane's place. Built on first request, like a
    /// surface, and dropped when the pane comes back or dies.
    private var standIns: [PaneID: PaneContainerView] = [:]
    /// Panes whose close control is held back whatever the canvas says. A pane on loan
    /// from a canvas it is the last pane of cannot be closed where it is shown: closing it
    /// would empty the canvas it belongs to.
    public var lockedOpen: Set<PaneID> = [] {
        didSet { for (paneID, container) in containers { container.canClose = canClose && !lockedOpen.contains(paneID) } }
    }
    private var canClose = true

    private struct Loan {
        weak var host: PaneSurfaceStore?
    }
    /// Panes whose `make` is on the stack right now. A tile that persists the layout while
    /// it is being built asks this store for its own record before it has one, and
    /// answering by building it again is a recursion with no floor.
    private var building: Set<PaneID> = []
    private let make: (PaneID) -> PaneContent
    /// Set by `LayoutStore` once it exists, so header controls drive the same commands the
    /// menu does rather than a parallel code path.
    /// Shared by reference with every container, so a callback set after some panes exist
    /// still reaches them.
    public let actions: PaneActions = .inert
    /// Called when a pane's surface is destroyed, so whoever owns the underlying resource
    /// — from M2, a PTY — can tear it down. This is the ONLY place a pane dies.
    public var onRelease: ((PaneID) -> Void)?
    /// Called once a pane's surface has been built and its record is known.
    public var onBuild: ((PaneID) -> Void)?
    /// Called on a HOST when a pane it was lent is taken out from under it — its home
    /// released it — so the host can drop the pane from whatever it was showing it in.
    /// Not a release: the pane's own store has already done that.
    public var onEvicted: ((PaneID) -> Void)?

    /// The surface colour every pane wears. Held here as well as pushed, so a pane built
    /// AFTER a theme change does not open in the theme the window launched with.
    public private(set) var theme: TerminalTheme = .dark

    public init(make: @escaping (PaneID) -> PaneContent) {
        self.make = make
    }

    /// Every pane this store has a view for: its own surfaces and the stand-ins for panes
    /// on loan, since a canvas parents both.
    public var activePanes: Set<PaneID> { Set(containers.keys).union(standIns.keys) }

    /// The panes currently away, and the stores showing them.
    public var lentPanes: [PaneID: PaneSurfaceStore] {
        loans.compactMapValues(\.host)
    }

    /// The tile for a pane, building it on first request and never again.
    ///
    /// A pane on loan answers with its stand-in: the real surface is on another canvas,
    /// and building a second one here would be a second process on the same id.
    public func surface(for paneID: PaneID) -> PaneContainerView {
        if let existing = containers[paneID] { return existing }
        if loans[paneID] != nil { return standIn(for: paneID) }
        building.insert(paneID)
        defer { building.remove(paneID) }
        let content = make(paneID)
        records[paneID] = content.record
        let container = PaneContainerView(paneID: paneID, descriptor: content.descriptor,
                                          kind: content.record.kind,
                                          content: content.view, actions: actions,
                                          theme: theme)
        container.paneAppearance = content.record.appearance
        containers[paneID] = container
        onBuild?(paneID)
        return container
    }

    /// The view this canvas shows for a pane, if it has one: the surface, or the stand-in
    /// while the pane is away. Nil for a pane never built — or one whose surface has
    /// moved to another store for good, as a pane window's has.
    public func existingSurface(for paneID: PaneID) -> PaneContainerView? {
        containers[paneID] ?? standIns[paneID]
    }

    /// The real surface, wherever it is: here, or on the canvas it is lent to.
    public func liveSurface(for paneID: PaneID) -> PaneContainerView? {
        containers[paneID] ?? loans[paneID]?.host?.containers[paneID]
    }

    /// Replace a pane's chrome text in place — used when a shell reports a new title or
    /// working directory. The surface itself is untouched.
    public func updateRecord(_ record: PaneRecord, for paneID: PaneID) {
        guard containers[paneID] != nil else { return }
        records[paneID] = record
        containers[paneID]?.update(descriptor: PaneDescriptor(icon: record.icon,
                                                              title: record.title,
                                                              subtitle: record.subtitle))
        containers[paneID]?.paneAppearance = record.appearance
    }

    /// The record for a pane, materialising it if it has never been shown. Restore writes
    /// the tree before any pane has a surface, and the document must still be complete.
    public func surfaceRecord(for paneID: PaneID) -> PaneRecord {
        // Away, the pane's record moves with it — a shell reports its folder to the canvas
        // showing it — so the live one is the host's, and the copy kept here is only for
        // the moment the host has gone.
        if let host = loans[paneID]?.host, let record = host.records[paneID] { return record }
        if let record = records[paneID] { return record }
        // Asked from inside this pane's own build: a stand-in, not a second build. The
        // persist that asked is debounced, and the one that follows the build has the
        // real record.
        if building.contains(paneID) { return PaneRecord(kind: .placeholder, title: "Pane") }
        _ = surface(for: paneID)
        return records[paneID] ?? PaneRecord(kind: .placeholder, title: "Pane")
    }

    /// The inner content view — at M2 this is the SwiftTerm view holding the live PTY.
    public func content(for paneID: PaneID) -> NSView? { existingSurface(for: paneID)?.content }

    /// Tear a pane down. The only place a surface is ever destroyed.
    public func release(_ paneID: PaneID) {
        records.removeValue(forKey: paneID)
        // A pane that dies while away dies where it is: the host loses the surface, with
        // a word so it can take the pane off its canvas, and the stand-in goes with it.
        // `onRelease` fires HERE, once — the host was only ever showing the pane.
        if let loan = loans.removeValue(forKey: paneID) {
            standIns.removeValue(forKey: paneID)?.removeFromSuperview()
            loan.host?.evict(paneID)
            onRelease?(paneID)
            return
        }
        guard let view = containers.removeValue(forKey: paneID) else { return }
        view.removeFromSuperview()
        onRelease?(paneID)
    }

    // MARK: Lending

    /// Show a pane on another canvas for a while, without it leaving this one.
    ///
    /// The live surface goes to `host` as `handOver` sends it — the same view, the same
    /// process, nothing built — and this store keeps the pane's place: its tree entry is
    /// untouched, and `surface(for:)` answers with a stand-in until `reclaim`. A loan
    /// rather than a move because the pane is coming back, and because a canvas whose only
    /// pane has gone to be looked at elsewhere must still be a canvas.
    ///
    /// Built first if it never has been, so there is a surface to lend rather than a pane
    /// the host would build a second time. False when the pane is unknown or already away.
    @discardableResult
    public func lend(_ paneID: PaneID, to host: PaneSurfaceStore) -> Bool {
        guard host !== self, loans[paneID] == nil else { return false }
        _ = surface(for: paneID)
        let record = records[paneID]
        guard handOver(paneID, to: host) else { return false }
        records[paneID] = record
        loans[paneID] = Loan(host: host)
        return true
    }

    /// Take a lent pane back: the surface returns, the stand-in goes. False when the pane
    /// was not away, or its host no longer has it — the pane was closed there, in which
    /// case the host's own release has already reached this store through `forfeit`.
    @discardableResult
    public func reclaim(_ paneID: PaneID) -> Bool {
        guard let loan = loans[paneID] else { return false }
        guard let host = loan.host, host.containers[paneID] != nil else {
            forfeit(paneID)
            return false
        }
        let record = records[paneID]
        loans[paneID] = nil
        standIns.removeValue(forKey: paneID)?.removeFromSuperview()
        host.handOver(paneID, to: self)
        if records[paneID] == nil, let record { records[paneID] = record }
        containers[paneID]?.canClose = canClose && !lockedOpen.contains(paneID)
        return true
    }

    /// The host closed a pane it was lent. The pane is gone — its surface was released
    /// there — so this store forgets it the way a release does, and says so, once.
    public func forfeit(_ paneID: PaneID) {
        guard loans.removeValue(forKey: paneID) != nil else { return }
        records.removeValue(forKey: paneID)
        standIns.removeValue(forKey: paneID)?.removeFromSuperview()
        onRelease?(paneID)
    }

    /// Lose a surface that was never this store's to keep: its home released it. Taken
    /// out of the view tree and forgotten, with no `onRelease` — the home has fired its own.
    private func evict(_ paneID: PaneID) {
        records.removeValue(forKey: paneID)
        containers.removeValue(forKey: paneID)?.removeFromSuperview()
        onEvicted?(paneID)
    }

    /// What this canvas shows while a pane is away: the pane's own header over a note
    /// saying where it is. Not a surface — nothing of the pane's is in it — and never
    /// handed to anyone.
    private func standIn(for paneID: PaneID) -> PaneContainerView {
        if let existing = standIns[paneID] { return existing }
        let record = surfaceRecord(for: paneID)
        let content = NSHostingView(rootView: VisitingStandIn(title: record.title))
        content.focusRingType = .none
        let container = PaneContainerView(paneID: paneID,
                                          descriptor: PaneDescriptor(icon: record.icon, title: record.title,
                                                                     subtitle: record.subtitle),
                                          kind: record.kind, content: content,
                                          actions: actions, theme: theme)
        container.paneAppearance = record.appearance
        container.canClose = canClose && !lockedOpen.contains(paneID)
        standIns[paneID] = container
        return container
    }

    /// Give a live pane to another store, as it is: the same view, the same process, its
    /// record with it. The one way a surface leaves a store WITHOUT being released — a pane
    /// moving to a canvas in another window of the same session. Taken out of the view
    /// tree here; the receiving canvas adopts it on its next `reconcile()`, as a canvas
    /// adopts every pane it finds unparented.
    @discardableResult
    public func handOver(_ paneID: PaneID, to other: PaneSurfaceStore) -> Bool {
        guard other !== self, let container = containers.removeValue(forKey: paneID) else { return false }
        let record = records.removeValue(forKey: paneID)
        container.removeFromSuperview()
        container.rewire(to: other.actions)
        container.theme = other.theme
        container.isFocused = false
        // Whatever the last canvas said about where the pane was from, it is not said here.
        container.visitStrip = nil
        other.containers[paneID] = container
        if let record { other.records[paneID] = record }
        return true
    }

    /// Release every surface no longer present in the tree.
    public func prune(keeping live: Set<PaneID>) {
        // Panes away on loan too: dropped from this tree, they die where they are shown.
        for paneID in Set(containers.keys).union(loans.keys) where !live.contains(paneID) {
            release(paneID)
        }
    }

    /// Exactly one pane wears the focus border at a time.
    public func setFocused(_ focused: PaneID) {
        for (paneID, container) in containers {
            container.isFocused = paneID == focused
        }
        for (paneID, standIn) in standIns {
            standIn.isFocused = paneID == focused
        }
    }

    /// Re-apply colours the panes cached in layer state. The focus border is a CGColor on
    /// a layer, set once — a changed accent reaches it only if it is pushed.
    public func refreshChrome() {
        for container in containers.values { container.refreshChrome() }
        for standIn in standIns.values { standIn.refreshChrome() }
    }

    /// Push a theme to every live pane. EVERY pane — a Todo and a shell are one surface
    /// each, and background opacity that reached only the shells was the setting looking
    /// broken on three panes out of four.
    public func apply(theme: TerminalTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        for container in containers.values { container.theme = theme }
        for standIn in standIns.values { standIn.theme = theme }
    }

    /// The last remaining pane hides its close control — there is nothing to close back to.
    public func setCanClose(_ canClose: Bool) {
        self.canClose = canClose
        for (paneID, container) in containers {
            container.canClose = canClose && !lockedOpen.contains(paneID)
        }
        for standIn in standIns.values { standIn.canClose = canClose }
    }
}
