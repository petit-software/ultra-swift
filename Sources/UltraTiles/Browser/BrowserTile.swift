import SwiftUI
import UltraDesign
import WebKit

/// A web page in a pane: an address field on top, the page, and the footer every tile has.
///
/// For the pages a developer keeps beside their shell — the dev server, the docs, the PR —
/// not for browsing. So there is no search, no tabs and no bookmarks; a pane is one page,
/// and a second page is a second pane.
///
/// The page is the CONTENT layer: opaque, like terminal text. The chrome around it is the
/// tile's own, so a browser pane reads as one more tile rather than a Safari window parked
/// on the canvas.
public struct BrowserTile: View {
    let context: TileContext
    let session: BrowserSession
    /// What is in the field. Follows the page while the field is not being edited, and
    /// stops following the moment it is, so a redirect cannot overwrite what you are typing.
    @State private var draft = ""
    @State private var fieldFocused = false

    public init(context: TileContext, session: BrowserSession) {
        self.context = context
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            addressBar
            if let error = session.error {
                NoticeBar(symbol: "exclamationmark.triangle.fill", message: error,
                          tint: Color.orange.opacity(0.18),
                          dismiss: { session.error = nil }) {
                    Button("Retry") { session.reload() }
                }
            }
            page
        }
        .tileFooter { footer }
        .onAppear {
            syncDraft()
            // An empty pane is a question — where to? — so the caret starts in the field.
            if session.requestedURL == nil { fieldFocused = true }
        }
        .onChange(of: session.requestedURL) { _, _ in syncDraft() }
        .onChange(of: session.addressFocusRequest) { _, _ in fieldFocused = true }
    }

    /// The field in the composer's capsule — the Todo pane's add field, so the one place a
    /// tile takes typing looks the same in every tile. A load progress line runs along its
    /// foot while a page is on its way.
    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: session.requestedURL?.scheme == "https" ? "lock.fill" : "globe")
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .frame(width: 16)
                .accessibilityHidden(true)
            SingleLineField(placeholder: "Address — localhost:3000, or a URL",
                            text: $draft, isFocused: $fieldFocused,
                            onSubmit: submit, onCancel: cancel)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(Token.Colour.label.opacity(fieldFocused ? 0.09 : 0.06))
        }
        .overlay(alignment: .bottom) { progressLine }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .contentShape(.rect)
        .onTapGesture { fieldFocused = true }
        .animation(Token.Motion.chromeFade, value: fieldFocused)
    }

    /// Inside the capsule's width, hugging its bottom edge. Gone when nothing is loading, so
    /// a settled page has no line under its address at all.
    private var progressLine: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Token.Colour.accent)
                .frame(width: max(0, proxy.size.width * session.progress), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.horizontal, 14)
        .opacity(session.isLoading ? 1 : 0)
        .animation(Token.Motion.chromeFade, value: session.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var page: some View {
        if session.requestedURL == nil {
            emptyState
        } else {
            BrowserWebView(session: session)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text("Type an address above")
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.secondaryLabel)
            Text("Open Location ⌘L")
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Navigation leads, the page's host trails — the footer rule every tile follows. Each
    /// control is also on Pane ▸ Browser with a key, so none of them is pointer-only.
    private var footer: some View {
        TileFooter(summary: session.requestedURL.map(BrowserSession.place(of:)) ?? "",
                   summaryHelp: session.requestedURL?.absoluteString) {
            TileFooterButton(symbol: "chevron.backward", help: "Back (⌘[)",
                             isEnabled: session.canGoBack) { session.goBack() }
            TileFooterButton(symbol: "chevron.forward", help: "Forward (⌘])",
                             isEnabled: session.canGoForward) { session.goForward() }
            if session.isLoading {
                TileFooterButton(symbol: "xmark", help: "Stop Loading") { session.stopLoading() }
            } else {
                TileFooterButton(symbol: "arrow.clockwise", help: "Reload (⌘R)",
                                 isEnabled: session.requestedURL != nil) { session.reload() }
            }
            TileFooterButton(symbol: session.isDark ? "sun.max" : "moon",
                             help: session.isDark ? "Show Page Light (⌃⌘L)"
                                                  : "Show Page Dark (⌃⌘L)") {
                session.toggleDark()
            }
            TileFooterButton(symbol: "safari", help: "Open in Default Browser",
                             isEnabled: session.requestedURL != nil) {
                session.openInDefaultBrowser()
            }
        }
    }

    private func submit() {
        guard session.open(text: draft) else { return }
        fieldFocused = false
        // Return means "go there", and what you do next is read or click the page — the
        // keyboard goes with you, so arrows and space scroll it straight away.
        DispatchQueue.main.async { session.focusPage() }
    }

    /// Escape puts back what the page is on and hands the keyboard to the page.
    private func cancel() {
        syncDraft(force: true)
        fieldFocused = false
        if session.requestedURL != nil {
            DispatchQueue.main.async { session.focusPage() }
        }
    }

    private func syncDraft(force: Bool = false) {
        guard force || !fieldFocused else { return }
        draft = session.requestedURL.map(BrowserAddress.display) ?? ""
    }
}

/// The session's web view, placed in the tile.
///
/// Returns the SAME `WKWebView` every time it is made, because the session owns it. A pane
/// rebuilt for any reason gets its page back, scrolled where it was, rather than a reload.
struct BrowserWebView: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

#Preview("Browser — a page", traits: .fixedLayout(width: 460, height: 360)) {
    let session = BrowserSession(url: URL(string: "http://localhost:3000"))
    session.showHTML("""
        <body style="font: 15px -apple-system; padding: 24px">
        <h2>Hello from localhost:3000</h2><p>A dev server's page, in a pane.</p></body>
        """)
    return BrowserTile(context: .inert(), session: session)
}

#Preview("Browser — dark", traits: .fixedLayout(width: 460, height: 360)) {
    let session = BrowserSession(url: URL(string: "http://localhost:3000"), isDark: true)
    session.showHTML("""
        <body style="font: 15px -apple-system; padding: 24px">
        <h2>A page with no dark theme</h2><p>Inverted, because it has none of its own.</p></body>
        """)
    return BrowserTile(context: .inert(), session: session)
}

#Preview("Browser — empty", traits: .fixedLayout(width: 460, height: 300)) {
    BrowserTile(context: .inert(), session: BrowserSession())
}

#Preview("Browser — server not running", traits: .fixedLayout(width: 460, height: 300)) {
    let session = BrowserSession(url: URL(string: "http://localhost:5173"))
    session.error = "Nothing is answering at localhost:5173 — is the server running?"
    return BrowserTile(context: .inert(), session: session)
}
