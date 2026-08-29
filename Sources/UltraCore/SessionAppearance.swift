import Foundation

/// How a session's row draws itself in the sidebar: which symbol, and in what colour.
///
/// Two strings rather than a symbol and a `Color`, because this type lives in `UltraCore`
/// and has to survive a round trip through disk. The symbol is an SF Symbol name; the tint
/// is the raw value of a `SessionTint` in `UltraDesign`, which owns what those names look
/// like. A tint this app no longer ships resolves back to the accent rather than to
/// nothing — a row with no colour would be a row that silently lost its identity.
public struct SessionAppearance: Codable, Equatable, Sendable {
    /// The split-pane mark every session started with, kept as the default so a user who
    /// never opens the picker sees exactly what they saw before it existed. Must match
    /// `SessionSymbols.fallback`; it is spelled again here because `UltraCore` is below
    /// `UltraDesign` and cannot see the catalogue.
    public static let defaultSymbol = "square.split.2x1.fill"
    /// Matches `SessionTint.accent` — the app's own accent, which is what the row used
    /// before it was customisable.
    public static let defaultTint = "accent"

    public var symbol: String
    public var tint: String

    public init(symbol: String = SessionAppearance.defaultSymbol,
                tint: String = SessionAppearance.defaultTint) {
        self.symbol = symbol
        self.tint = tint
    }

    public static let `default` = SessionAppearance()

    /// Nothing to store. `set` writes nothing for this, so an untouched project leaves no
    /// key behind and picking the defaults back is the same as never having chosen.
    public var isDefault: Bool { self == .default }
}

/// Where a session's icon is remembered: one entry per PROJECT, in `UserDefaults`.
///
/// The same shape `TodoStore` uses for a todo file's location — a defaults key built from
/// the project's path, written through the moment the user chooses, read back whenever the
/// project is opened again. That is deliberate: like a todo list's location, this is a
/// preference ABOUT a project rather than part of a window's layout, so it must survive the
/// workspace document being reset, and must be the same icon whichever window the project
/// is opened in.
///
/// Keyed by `WorkspaceDocument.canonical`, not by the raw path. A project arrives spelled
/// several ways — trailing slash from a drag, `~` from a config, a symlink from `/tmp` —
/// and three spellings would be three icons for one project.
public enum SessionAppearanceStore {
    public static func key(forDirectory directory: String) -> String {
        "ultra.sessionAppearance." + WorkspaceDocument.canonical(directory)
    }

    /// The stored icon, or the default. A project with no directory — a workspace that
    /// predates the field and could not be matched to one — is not customisable, because
    /// there is no key to file it under; it gets the default and keeps it.
    public static func appearance(forDirectory directory: String?,
                                  defaults: UserDefaults = .standard) -> SessionAppearance {
        guard let directory,
              let data = defaults.data(forKey: key(forDirectory: directory)),
              let decoded = try? JSONDecoder().decode(SessionAppearance.self, from: data)
        else { return .default }
        return decoded
    }

    /// Write through immediately, the way a todo edit does — a choice made in a picker that
    /// is not on disk by the time the picker closes is a choice a crash can take away.
    ///
    /// Storing the default REMOVES the key instead of writing it. Defaults are what an
    /// absent key already means, so writing them would only leave a row of dead entries
    /// that say the same thing as silence.
    public static func set(_ appearance: SessionAppearance, forDirectory directory: String?,
                           defaults: UserDefaults = .standard) {
        guard let directory else { return }
        let key = key(forDirectory: directory)
        guard !appearance.isDefault else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: key)
    }

    public static func reset(forDirectory directory: String?,
                             defaults: UserDefaults = .standard) {
        set(.default, forDirectory: directory, defaults: defaults)
    }
}
