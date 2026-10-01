import SwiftUI
import UltraDesign

/// What a tile has to say about its file, in one value every tile can hand to a toast.
///
/// Four tiles had the words written out in their own `message(for:)` — the Editor and the
/// Todo list both said "Reloaded — the file changed on disk", in two files, and would have
/// drifted the first time one was reworded. The words live here once, and a tile's own
/// notice enum maps onto one of these.
///
/// A notice knows whether it STAYS. One that reports something already done — the file was
/// reloaded, nothing to decide — leaves on its own. One that needs a decision, or says that
/// something failed, waits to be read.
public struct TileNotice: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        /// Something happened and was handled: reloaded.
        case info
        /// Something needs attention or a decision: a conflict, a page that would not load.
        case warning
        /// Something did not happen: a save that failed.
        case failure
    }

    public var symbol: String
    public var message: String
    public var tone: Tone
    /// Whether the toast waits to be closed. False, and it leaves after `TileToast.linger`.
    public var stays: Bool

    public init(symbol: String, message: String, tone: Tone, stays: Bool) {
        self.symbol = symbol
        self.message = message
        self.tone = tone
        self.stays = stays
    }

    /// The file changed on disk and there was nothing here to lose, so it was reloaded.
    public static let reloadedFromDisk = TileNotice(
        symbol: "arrow.clockwise.circle.fill",
        message: "Reloaded — the file changed on disk",
        tone: .info, stays: false)

    /// It changed on disk AND there are unsaved edits here. Nothing was overwritten, and
    /// the toast offers Reload beside Close so the decision is the user's.
    public static let conflict = TileNotice(
        symbol: "exclamationmark.triangle.fill",
        message: "Changed on disk while you were editing. Nothing was overwritten.",
        tone: .warning, stays: true)

    /// A save that did not happen, with the system's reason.
    public static func couldNotSave(_ reason: String) -> TileNotice {
        TileNotice(symbol: "xmark.octagon.fill", message: "Could not save: \(reason)",
                   tone: .failure, stays: true)
    }

    /// Anything else that did not happen, in the words the tile already has for it.
    public static func failed(_ message: String) -> TileNotice {
        TileNotice(symbol: "xmark.octagon.fill", message: message, tone: .failure, stays: true)
    }

    /// Something that could not be reached or shown, offered with a way to try again.
    public static func unreachable(_ message: String) -> TileNotice {
        TileNotice(symbol: "exclamationmark.triangle.fill", message: message,
                   tone: .warning, stays: true)
    }
}

/// The toast a tile floats over the foot of its content when something happened to its
/// file: reloaded, changed underneath an edit, could not be saved.
///
/// It was a strip across the top of the tile. A strip takes a row of its own, so every
/// reload pushed the text being edited down a line and pulled it back up when the strip was
/// closed — the one thing a notice about the file must not do is move the file. A toast
/// floats instead: glass, so the content stays legible through it; rounded at 12pt, so it
/// reads as something that arrived rather than as part of the tile, and not as a pill button; at the foot and above the footer,
/// 4pt from the pane's sides, so it sits where the eye is not and never covers the title.
///
/// A FILLED symbol on the left, because the line is small type and an outlined glyph at that
/// size reads as a smudge. An `⌫`-shaped close control on the right, where every dismiss
/// control on the Mac lives, rather than the word "Dismiss" — a notice is a one-line aside,
/// and a word-sized button made it read as a dialog. Anything the notice offers beyond
/// closing — a Reload, a Retry — goes in `actions`, between the message and the close
/// control.
///
/// Glass on the content layer is the exception docs/02-DESIGN-LANGUAGE.md makes for HUDs:
/// a toast is one, it is the only thing that floats inside a tile, and the informational
/// kind is gone in seconds.
struct TileToast<Actions: View>: View {
    let notice: TileNotice
    let dismiss: () -> Void
    @ViewBuilder var actions: () -> Actions

    /// How long an informational toast stays before leaving on its own. Long enough to be
    /// read twice; a toast nobody caught is a toast that was not needed.
    static var linger: Duration { .seconds(4) }

    @State private var isHovering = false

    init(_ notice: TileNotice,
         dismiss: @escaping () -> Void,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.notice = notice
        self.dismiss = dismiss
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.symbol)
                .foregroundStyle(symbolColour)
                .accessibilityHidden(true)
            Text(notice.message)
                .foregroundStyle(Token.Colour.label)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .buttonStyle(.plain)
                .foregroundStyle(Token.Colour.accent)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close notice")
        }
        .font(Token.Type_.body)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .ultraToastGlass()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.message)
        .task(id: notice) {
            guard !notice.stays else { return }
            try? await Task.sleep(for: Self.linger)
            // The pointer on it is a reader mid-sentence. Wait for them to leave, then go.
            while isHovering, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !Task.isCancelled { dismiss() }
        }
    }

    /// The tone is carried by the symbol alone — the toast itself is never tinted, so a
    /// warning is a warning by its glyph and its words, not by an orange band the glass
    /// would have to fight. System colours, which hold under Increase Contrast.
    private var symbolColour: Color {
        switch notice.tone {
        case .info: Token.Colour.secondaryLabel
        case .warning: Color(nsColor: .systemOrange)
        case .failure: Color(nsColor: .systemRed)
        }
    }
}

public extension View {
    /// Floats a tile's notice over the foot of its content.
    ///
    /// Applied to the content and BEFORE `tileFooter`, so the toast lives in the content's
    /// rectangle: its bottom edge is the top of the footer band, which puts the toast 4pt
    /// above the footer and 4pt in from each side of the pane. The frame is filled here so
    /// that a short content stack still anchors the toast at the foot, not at its own end.
    ///
    /// It arrives from below and leaves the same way; under Reduce Motion it fades.
    func tileToast<Actions: View>(_ notice: TileNotice?,
                                  dismiss: @escaping () -> Void,
                                  @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) -> some View {
        let reduceMotion = Token.Environment_.reduceMotion
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let notice {
                    TileToast(notice, dismiss: dismiss, actions: actions)
                        .padding(Token.Space.toastInset)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? Token.Motion.chromeFade : Token.Motion.toast,
                       value: notice)
    }
}

#Preview("Toasts", traits: .fixedLayout(width: 460, height: 420)) {
    VStack(spacing: 12) {
        ForEach([TileNotice.reloadedFromDisk,
                 .conflict,
                 .couldNotSave("permission denied"),
                 .unreachable("Nothing is answering at localhost:5173 — is the server running?")],
                id: \.message) { notice in
            TileToast(notice, dismiss: {}) {
                if notice == .conflict { Button("Reload") {} }
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Token.Colour.paneBackground)
}

#Preview("Toast in a tile", traits: .fixedLayout(width: 460, height: 300)) {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(0..<12, id: \.self) { line in
            Text("line \(line + 1)  let value = compute(\(line))")
                .font(Token.Type_.mono)
                .foregroundStyle(Token.Colour.label)
        }
        Spacer()
    }
    .padding(Token.Space.tileBodyInset)
    .tileToast(.conflict, dismiss: {}) { Button("Reload") {} }
    .tileFooter {
        TileFooter(summary: "~/Repo/example/Sources/App.swift", truncation: .head) {
            TileFooterButton(symbol: "doc.badge.plus", help: "New File") {}
        }
    }
    .background(Token.Colour.paneBackground)
}
