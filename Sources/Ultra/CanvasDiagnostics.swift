import AppKit
import Foundation
import UltraCanvas
import UltraCore
import UltraLayout

/// What every window is holding, as text: its projects, the one selected, each canvas in
/// it, and where every pane's view actually is.
///
/// For the fault that cannot be reproduced on demand — a project selected in the sidebar
/// over a canvas with no panes, or with another project's. The model (`SessionList`), the
/// view tree (which `SplitCanvasView` is in the window) and the panes (which view each is
/// parented in) are three things that are supposed to agree; this writes all three down
/// at the moment they do not. Help ▸ Copy Canvas Diagnostics, and the palette.
///
/// Read-only. It asks for no surface that does not exist already — `existingSurface`,
/// never `surface(for:)` — so taking the picture does not build a pane or start a shell.
@MainActor
enum CanvasDiagnostics {

    /// Copy the report, and keep a file of it: a clipboard is overwritten by the next
    /// copy, and the moment it describes does not come back.
    static func copy() {
        let text = report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let folder = AppSupport.directory.appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? text.write(to: folder.appendingPathComponent("canvas-\(stamp).txt"),
                        atomically: true, encoding: .utf8)
    }

    static func report() -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary
        out.append("Ultra canvas diagnostics — \(ISO8601DateFormatter().string(from: Date()))")
        out.append("build: \(Bundle.main.bundleIdentifier ?? "swift run") "
                   + "\(info?["CFBundleShortVersionString"] as? String ?? "?") "
                   + "(\(info?["CFBundleVersion"] as? String ?? "?"))")
        out.append("app: active=\(NSApp.isActive) key=\(name(NSApp.keyWindow)) main=\(name(NSApp.mainWindow))")
        // A canvas found missing and put back, this run: see `CanvasWatch`.
        out.append("canvas remounts: \(CanvasWatch.remounts)")

        let overview = AgentsOverview.shared
        out.append("")
        out.append("agents overview: open=\(overview.isOpen) in=\(name(overview.list?.window)) "
                   + "store=\(short(overview.store.workspaceID)) visitors=\(overview.store.visitors.count)")

        // The model: every list, live window or not. A list with sessions and no window
        // is itself a finding.
        let lists = SessionList.all
        for (index, list) in lists.enumerated() {
            out.append("")
            out.append("list \(index): window=\(name(list.window)) sessions=\(list.sessions.count) "
                       + "selected=\(list.selectedID.map(short) ?? "nil") "
                       + "showsAgents=\(flag(list.ui?.showsAgents)) belt=\(flag(list.ui?.showsTabBelt))")
            let ids = list.sessions.map(\.workspaceID)
            if Set(ids).count != ids.count { out.append("  !! two sessions share a workspace id") }
            if let selected = list.selectedID, !ids.contains(selected) {
                out.append("  !! the selected id is not one of the sessions")
            }
            for store in list.sessions {
                let mark = store.workspaceID == list.selectedID ? "*" : " "
                out += describe(store, mark: mark, indent: "  ")
            }
        }

        // Running, and in no list: left by a closed window, or lost.
        let held = Set(lists.flatMap(\.sessions).map(\.workspaceID))
        let unheld = ShellWorkspace.Registry.stores.values.filter { !held.contains($0.workspaceID) }
        if !unheld.isEmpty {
            out.append("")
            out.append("running, in no list:")
            for store in unheld { out += describe(store, mark: " ", indent: "  ") }
        }
        for (id, store) in ShellWorkspace.Registry.stores where store.workspaceID != id {
            out.append("!! registry key \(short(id)) holds store \(short(store.workspaceID))")
        }

        // The view tree: every window there is, and every canvas in each.
        out.append("")
        out.append("windows:")
        for window in NSApp.windows {
            let found = canvases(in: window.contentView)
            // Panels, menus and the status item's window are noise unless a canvas is in one.
            guard !found.isEmpty || (window.isVisible && window.styleMask.contains(.titled))
            else { continue }
            out.append("  \(name(window)) \(type(of: window)) visible=\(window.isVisible) "
                       + "key=\(window.isKeyWindow) mini=\(window.isMiniaturized) "
                       + "onScreen=\(window.occlusionState.contains(.visible)) "
                       + "frame=\(rect(window.frame)) sheets=\(window.sheets.count)")
            for canvas in found {
                let store = canvas.store
                let panes = store.surfaces.activePanes.filter {
                    store.surfaces.existingSurface(for: $0)?.isDescendant(of: canvas) ?? false
                }
                let strangers = paneViews(in: canvas).filter { !panes.contains($0.paneID) }
                out.append("    canvas \(label(store)) frame=\(rect(canvas.frame)) "
                           + "hidden=\(canvas.isHiddenOrHasHiddenAncestor) alpha=\(alpha(canvas)) "
                           + "panes=\(panes.count)/\(store.tree.paneCount) "
                           + "needsLayout=\(canvas.needsLayout)")
                if !strangers.isEmpty {
                    out.append("    !! \(strangers.count) pane views in it are not its store's: "
                               + strangers.map { short($0.paneID) }.joined(separator: " "))
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - One session

    private static func describe(_ store: LayoutStore, mark: String, indent: String) -> [String] {
        var out: [String] = []
        let surfaces = store.surfaces
        out.append("\(indent)\(mark) \(label(store)) dir=\(store.workspaceDirectory ?? "—") "
                   + "tree=\(store.tree.paneCount) surfaces=\(surfaces.activePanes.count) "
                   + "lent=\(surfaces.lentPanes.count) visitors=\(store.visitors.count) "
                   + "paneWindows=\(store.paneWindows.count) bounds=\(rect(store.canvasBounds)) "
                   // A pane window's store is its session's, and is not registered itself.
                   + (store.session === store
                      ? "registered=\(ShellWorkspace.Registry.stores[store.workspaceID] === store)" : "pane window"))
        for paneID in store.tree.paneIDs {
            guard let view = surfaces.existingSurface(for: paneID) else {
                out.append("\(indent)    \(short(paneID)) not built")
                continue
            }
            let canvas = enclosingCanvas(of: view)
            let place = canvas.map { "canvas \(label($0.store))" }
                ?? (view.superview == nil ? "no superview" : "in \(type(of: view.superview!))")
            let kind = surfaces.records[paneID]?.kind.rawValue ?? "?"
            out.append("\(indent)    \(short(paneID)) \(kind) → \(place) "
                       + "window=\(name(view.window)) hidden=\(view.isHidden) frame=\(rect(view.frame))")
        }
        for window in store.paneWindows {
            out += describe(window, mark: "↳", indent: indent + "  ")
        }
        return out
    }

    // MARK: - Walking views

    private static func canvases(in view: NSView?) -> [SplitCanvasView] {
        guard let view else { return [] }
        var out: [SplitCanvasView] = []
        if let canvas = view as? SplitCanvasView { out.append(canvas) }
        for subview in view.subviews { out += canvases(in: subview) }
        return out
    }

    /// The pane views parented in a canvas, without going into a pane's own content.
    private static func paneViews(in view: NSView) -> [PaneContainerView] {
        var out: [PaneContainerView] = []
        for subview in view.subviews {
            if let pane = subview as? PaneContainerView { out.append(pane) }
            else { out += paneViews(in: subview) }
        }
        return out
    }

    private static func enclosingCanvas(of view: NSView) -> SplitCanvasView? {
        var current = view.superview
        while let candidate = current {
            if let canvas = candidate as? SplitCanvasView { return canvas }
            current = candidate.superview
        }
        return nil
    }

    // MARK: - Spelling

    private static func label(_ store: LayoutStore) -> String {
        if store === AgentsOverview.shared.store { return "\(short(store.workspaceID)) «Agents overview»" }
        return "\(short(store.workspaceID)) «\(store.workspaceTitle)»"
    }

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private static func name(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        return "#\(window.windowNumber) «\(window.title)»"
    }

    private static func flag(_ value: Bool?) -> String { value.map { "\($0)" } ?? "no ui" }

    private static func rect(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// The opacity the canvas is drawn with, its ancestors' included: a view mid-fade in a
    /// SwiftUI transition is at full `alphaValue` under a layer that is not.
    private static func alpha(_ view: NSView) -> String {
        var value = CGFloat(view.alphaValue)
        var layer = view.layer
        while let current = layer {
            value *= CGFloat((current.presentation() ?? current).opacity)
            layer = current.superlayer
        }
        return String(format: "%.2f", value)
    }
}
