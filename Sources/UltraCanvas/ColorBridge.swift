import AppKit
import SwiftUI

/// AppKit drawing needs `NSColor`; the tokens are declared as SwiftUI `Color`.
/// One conversion point rather than parallel palettes.
enum Color_Bridge {}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}
