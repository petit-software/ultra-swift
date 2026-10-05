import SwiftUI
import UltraDesign
import WebKit

/// Web pages in a pane: a row of tabs when there is more than one, an address field, the
/// page, and the footer every tile has.
///
/// For the pages a developer keeps beside their shell — the dev server, the docs, the PR —
/// not for browsing. So there is no search and no bookmarks. There ARE tabs: a pane was one
/// page for a while, and reading documentation that way meant a pane for every link worth
/// keeping open.
///
/// The page is the CONTENT layer: opaque, like terminal text. The chrome around it is the
/// tile's own, so a browser pane reads as one more tile rather than a Safari window parked
/// on the canvas.
public struct BrowserTile: View {
    let context: TileContext
    let tabs: BrowserTabs

    public init(context: TileContext, tabs: BrowserTabs) {
        self.context = context
        self.tabs = tabs
    }

    /// The tab that is showing: what the footer, the toast and the page are all about.
    private var session: BrowserSession { tabs.selected }

    public var body: some View {
        VStack(spacing: 0) {
            // Absent with one tab, which is a pane as it always was: a strip holding a
            // single tab is a band of chrome saying what the header already says.
            if tabs.sessions.count > 1 {
                BrowserTabStrip(tabs: tabs)
            }
            // Keyed, so each tab has an address field of its own — what was being typed in
            // one is not carried into the next — and the web view in the pane is the
            // selected tab's rather than the first one that was ever put there.
            BrowserPage(session: session)
                .id(session.id)
        }
        .tileToast(session.error.map(TileNotice.unreachable), dismiss: { session.error = nil }) {
            Button("Retry") { session.reload() }
        }
        .tileFooter { footer }
        // Another tab is another web view, and the one that had the keyboard has just left
        // the window. A turn later, so the new one is in it. An empty tab takes the caret
        // in its address field instead, as it appears.
        .onChange(of: tabs.selectedID) { _, _ in
            let session = tabs.selected
            guard session.requestedURL != nil else { return }
            DispatchQueue.main.async { session.focusPageIfUnclaimed() }
        }
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
            // Here rather than at the end of the tab strip: the strip is not there with one
            // tab, which is exactly when a second is asked for.
            TileFooterButton(symbol: "plus", help: "New Tab (⌃⌘T)") { tabs.newTab() }
            TileFooterButton(symbol: session.isDark ? "sun.max" : "moon",
                             help: session.isDark ? "Show Page Light (⌃⌘L)"
                                                  : "Show Page Dark (⌃⌘L)") {
                session.toggleDark()
            }
            TileFooterButton(symbol: "wrench.and.screwdriver", help: "Show Web Inspector (⌥⌘I)",
                             isEnabled: session.requestedURL != nil) {
                session.showInspector()
            }
            TileFooterButton(symbol: "arrow.trianglehead.2.clockwise",
                             help: "Empty Caches and Reload — cookies and logins stay") {
                session.emptyCaches()
            }
            TileFooterButton(symbol: "safari", help: "Open in Default Browser",
                             isEnabled: session.requestedURL != nil) {
                session.openInDefaultBrowser()
            }
        }
    }
}

/// The pane's pages as the tile's row of tabs — `TileTabStrip`, which the editor shares.
///
/// A view of its own so a page's title arriving redraws the strip and not the page. The
/// keyboard path along the row is ⌃⌘] / ⌃⌘[ (Pane ▸ Browser ▸ Next / Previous Browser Tab).
private struct BrowserTabStrip: View {
    let tabs: BrowserTabs

    var body: some View {
        TileTabStrip(tabs: tabs.sessions.map { session in
                         TileTab(id: session.id,
                                 title: Self.title(of: session),
                                 symbol: "globe",
                                 help: session.requestedURL?.absoluteString ?? "Nothing loaded yet",
                                 accessibilityLabel: "Page, \(Self.title(of: session))")
                     },
                     selectedID: tabs.selectedID,
                     label: "Open pages",
                     truncation: .tail,
                     // The strip and the address field under it are one block of chrome,
                     // and the line belongs under the block — the page's own hairline.
                     showsDivider: false,
                     select: { tabs.select($0) },
                     close: { tabs.close($0) })
    }

    /// The page's own title; until it has one, where it is; and for a tab with no page,
    /// what it is.
    static func title(of session: BrowserSession) -> String {
        session.title ?? session.requestedURL.map(BrowserSession.place(of:)) ?? "New Tab"
    }
}

/// One tab's worth of the pane: its address field, and its page between two hairlines.
private struct BrowserPage: View {
    let session: BrowserSession
    /// What is in the field. Follows the page while the field is not being edited, and
    /// stops following the moment it is, so a redirect cannot overwrite what you are typing.
    @State private var draft = ""
    @State private var fieldFocused = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            // The page is somebody else's surface — usually white, in a pane that is not —
            // and it ran straight into the tile's chrome at both ends. A hairline where it
            // starts and another where it stops, so the page has edges of its own.
            hairline
            page
            hairline
        }
        .onAppear {
            syncDraft()
            // An empty pane is a question — where to? — so the caret starts in the field.
            if session.requestedURL == nil { fieldFocused = true }
        }
        .onChange(of: session.requestedURL) { _, _ in syncDraft() }
        .onChange(of: session.addressFocusRequest) { _, _ in fieldFocused = true }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Token.Colour.divider)
            .frame(height: Token.Space.hairline)
            .accessibilityHidden(true)
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

/// The browser pane's content: the tile, hosted, with one opinion about the keyboard.
///
/// A focused browser pane with a page in it gives the keyboard to the PAGE, so arrows and
/// space scroll it and ⌘L is how the address is reached. An empty tab gives it to the
/// address field, because there is nothing else to type into. See `KeyboardTargetProviding`.
final class BrowserHostingView: NSHostingView<BrowserTile>, KeyboardTargetProviding {
    private let tabs: BrowserTabs

    init(tile: BrowserTile, tabs: BrowserTabs) {
        self.tabs = tabs
        super.init(rootView: tile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @available(*, unavailable)
    required init(rootView: BrowserTile) { fatalError("use init(tile:tabs:)") }

    /// The page of the tab that is SHOWING: the other tabs' web views are not in the pane.
    var preferredKeyboardTarget: NSView? {
        let session = tabs.selected
        return session.requestedURL == nil ? nil : session.existingWebView
    }
}

/// The session's web view, placed in the tile.
///
/// Returns the SAME `WKWebView` every time it is made, because the session owns it. A pane
/// rebuilt for any reason — and a tab come back to — gets its page as it was left, scrolled
/// where it was, rather than a reload.
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
    return BrowserTile(context: .inert(), tabs: BrowserTabs(session))
}

#Preview("Browser — dark", traits: .fixedLayout(width: 460, height: 360)) {
    let session = BrowserSession(url: URL(string: "http://localhost:3000"), isDark: true)
    session.showHTML("""
        <body style="font: 15px -apple-system; padding: 24px">
        <h2>A page with no dark theme</h2><p>Inverted, because it has none of its own.</p></body>
        """)
    return BrowserTile(context: .inert(), tabs: BrowserTabs(session))
}

#Preview("Browser — empty", traits: .fixedLayout(width: 460, height: 300)) {
    BrowserTile(context: .inert(), tabs: BrowserTabs())
}

#Preview("Browser — three tabs", traits: .fixedLayout(width: 460, height: 360)) {
    let tabs = BrowserTabs(urls: [URL(string: "http://localhost:3000"),
                                  URL(string: "https://developer.apple.com/documentation/webkit"),
                                  nil],
                           selected: 0)
    tabs.selected.showHTML("""
        <body style="font: 15px -apple-system; padding: 24px">
        <h2>Hello from localhost:3000</h2><p>The first of three tabs.</p></body>
        """)
    return BrowserTile(context: .inert(), tabs: tabs)
}

#Preview("Browser — server not running", traits: .fixedLayout(width: 460, height: 300)) {
    let session = BrowserSession(url: URL(string: "http://localhost:5173"))
    session.error = "Nothing is answering at localhost:5173 — is the server running?"
    return BrowserTile(context: .inert(), tabs: BrowserTabs(session))
}
