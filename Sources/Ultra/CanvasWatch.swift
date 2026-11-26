import AppKit
import UltraCanvas
import UltraLayout
import os

/// Checks, a moment after a project is selected, that its canvas is in the window — and
/// puts it there when it is not.
///
/// The fault this is for was caught once by `CanvasDiagnostics`, eight seconds into a
/// launch: five projects restored, one selected, and no `SplitCanvasView` in the window at
/// all — every pane "not built". The system log of that launch has four `AttributeGraph:
/// Cycle detected` errors at the moment the sessions were restored, and on no other
/// launch. A cycle makes SwiftUI give up on the update it was in, and the update given up
/// on was the one that swaps the detail column's empty placeholder for the canvas; the
/// model had changed, Observation had said so once, and nothing was going to say it again
/// until another project was clicked.
///
/// What closes the cycle is not known — it has not been made to happen again. So this
/// does not prevent it. It looks at what the window holds rather than at what the model
/// says, and when the two disagree it changes `UIState.canvasEpoch`, which `RootView`
/// reads as the identity of the canvas: a new value is a new canvas, built from the model
/// as it is now. Rebuilding a canvas is safe for the reason switching projects is — the
/// panes are owned above the view layer (`PaneSurfaceStore`) and are re-adopted.
@MainActor
enum CanvasWatch {
    /// How many times a canvas has been put back, this run. In the diagnostics report.
    private(set) static var remounts = 0

    private static let log = Logger(subsystem: "software.petit.ultra", category: "canvas")
    private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// The waits before each look. The first is longer than the slowest mount measured at
    /// launch (130ms after the window is up); the rest are for a remount that was itself
    /// lost. Three, and then it stops: a window that cannot hold a canvas is not helped by
    /// being rebuilt forever.
    private static let waits: [Duration] = [.milliseconds(400), .milliseconds(600), .seconds(1)]

    /// Look at `list`'s window after the selection has had time to reach the screen.
    /// A later call for the same list replaces an earlier one still waiting.
    static func verify(_ list: SessionList) {
        let key = ObjectIdentifier(list)
        pending[key]?.cancel()
        pending[key] = Task { [weak list] in
            for wait in waits {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let list, let ui = list.ui else { return }
                guard let window = list.window, let wanted = wanted(in: list, ui: ui) else { continue }
                if holdsCanvas(of: wanted, in: window.contentView) { break }
                remounts += 1
                log.error("no canvas for the selected project in its window; remounting (\(remounts))")
                ui.canvasEpoch &+= 1
            }
            if !Task.isCancelled { pending[key] = nil }
        }
    }

    /// The store whose canvas the window should be showing.
    private static func wanted(in list: SessionList, ui: UIState) -> LayoutStore? {
        ui.showsAgents ? AgentsOverview.shared.store : list.selected
    }

    /// Whether a canvas bound to `store` is somewhere under `view`.
    static func holdsCanvas(of store: LayoutStore, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let canvas = view as? SplitCanvasView, canvas.store === store { return true }
        return view.subviews.contains { holdsCanvas(of: store, in: $0) }
    }
}
