import AppKit
import UltraCore
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
    private let make: (PaneID) -> PaneContent
    /// Set by `LayoutStore` once it exists, so header controls drive the same commands the
    /// menu does rather than a parallel code path.
    public var actions: PaneActions = .inert
    /// Called when a pane's surface is destroyed, so whoever owns the underlying resource
    /// — from M2, a PTY — can tear it down. This is the ONLY place a pane dies.
    public var onRelease: ((PaneID) -> Void)?

    public init(make: @escaping (PaneID) -> PaneContent) {
        self.make = make
    }

    public var activePanes: Set<PaneID> { Set(containers.keys) }

    /// The tile for a pane, building it on first request and never again.
    public func surface(for paneID: PaneID) -> PaneContainerView {
        if let existing = containers[paneID] { return existing }
        let content = make(paneID)
        records[paneID] = content.record
        let container = PaneContainerView(paneID: paneID, descriptor: content.descriptor,
                                          content: content.view, actions: actions)
        containers[paneID] = container
        return container
    }

    public func existingSurface(for paneID: PaneID) -> PaneContainerView? { containers[paneID] }

    /// Replace a pane's chrome text in place — used when a shell reports a new title or
    /// working directory. The surface itself is untouched.
    public func updateRecord(_ record: PaneRecord, for paneID: PaneID) {
        guard containers[paneID] != nil else { return }
        records[paneID] = record
        containers[paneID]?.update(descriptor: PaneDescriptor(icon: record.icon,
                                                              title: record.title,
                                                              subtitle: record.subtitle))
    }

    /// The record for a pane, materialising it if it has never been shown. Restore writes
    /// the tree before any pane has a surface, and the document must still be complete.
    public func surfaceRecord(for paneID: PaneID) -> PaneRecord {
        if let record = records[paneID] { return record }
        _ = surface(for: paneID)
        return records[paneID] ?? PaneRecord(kind: .placeholder, title: "Pane")
    }

    /// The inner content view — at M2 this is the SwiftTerm view holding the live PTY.
    public func content(for paneID: PaneID) -> NSView? { containers[paneID]?.content }

    /// Tear a pane down. The only place a surface is ever destroyed.
    public func release(_ paneID: PaneID) {
        records.removeValue(forKey: paneID)
        guard let view = containers.removeValue(forKey: paneID) else { return }
        view.removeFromSuperview()
        onRelease?(paneID)
    }

    /// Release every surface no longer present in the tree.
    public func prune(keeping live: Set<PaneID>) {
        for paneID in containers.keys where !live.contains(paneID) { release(paneID) }
    }

    /// Exactly one pane wears the focus border at a time.
    public func setFocused(_ focused: PaneID) {
        for (paneID, container) in containers {
            container.isFocused = paneID == focused
        }
    }

    /// The last remaining pane hides its close control — there is nothing to close back to.
    public func setCanClose(_ canClose: Bool) {
        for container in containers.values { container.canClose = canClose }
    }
}
