import SwiftUI
import UltraDesign

public extension View {
    /// Leave room for the pane header, which floats OVER a tile rather than sitting above it.
    ///
    /// `safeAreaInset` rather than padding on purpose: a scroll view then starts its content
    /// below the header but still DRAWS through it, which is the whole point — the header's
    /// blur needs something moving underneath to be worth having.
    func tileHeaderInset() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: Token.Space.tileHeaderHeight)
        }
    }
}

import AppKit

/// Ask the user where a tile's file should live.
///
/// A save panel rather than an open panel: the point is usually to CREATE the list
/// somewhere — `docs/TODO.md` in a repo that does not have one yet — and an open panel
/// cannot name a file that does not exist.
@MainActor
public func chooseTileFile(title: String,
                           suggestedName: String,
                           directory: URL,
                           allowedExtensions: [String]) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.nameFieldStringValue = suggestedName
    panel.directoryURL = directory
    panel.allowedContentTypes = []
    panel.allowsOtherFileTypes = true
    // Existing files are the normal case here — the panel is picking a location, not
    // guaranteeing a new document — so the overwrite warning would be wrong.
    panel.isExtensionHidden = false
    panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url : nil
}
