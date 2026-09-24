import AppKit
import Foundation
import WebKit

/// One browser pane's page: the web view, and what the pane's chrome needs to know about it.
///
/// Owned by `TileFactory`, not by the view, for the reason a shell's PTY and a chat's
/// conversation are: a pane is rebuilt whenever it is restored, converted or retargeted, and
/// a web view living in the view would reload the page — losing its scroll position, its
/// form state and its history — every time the layout so much as hiccuped.
///
/// The `WKWebView` is made on first use rather than in `init`. A session exists for every
/// browser pane in a restored workspace, including the ones in sessions nobody has switched
/// to yet, and each web view is a WebContent process of its own.
@MainActor
@Observable
public final class BrowserSession {
    /// The page this pane is on — or will be, once its web view exists. What the pane's
    /// record persists, so a restored workspace reopens it.
    public private(set) var requestedURL: URL?
    public private(set) var title: String?
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isLoading = false
    /// 0…1, for the progress line under the address field.
    public private(set) var progress: Double = 0
    /// Why the last load failed, in words, for the notice bar. Cleared by the next load.
    public var error: String?
    /// Bumped to ask the pane to put the caret in its address field — Open Location (⌘L)
    /// arrives from the menu bar, which has no other way to reach a field inside a pane.
    public private(set) var addressFocusRequest = 0
    /// Whether the page is shown dark. Per pane, and saved with it: the dev server in one
    /// pane and the docs in the next are different pages with different ideas of a theme.
    ///
    /// Dark does two things. The web view's appearance is set dark, so a page with a dark
    /// theme of its own — `prefers-color-scheme` — uses it, which is always the better
    /// result. A page with no dark theme, which is most dev servers, is inverted instead,
    /// with its images and video inverted back so photos keep their colours. Light pins the
    /// page light, whatever the app's own appearance is.
    public private(set) var isDark: Bool

    /// The page or its title changed: the pane's header and its saved record follow.
    @ObservationIgnored public var onChange: ((URL?, String?) -> Void)?

    @ObservationIgnored private var madeWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: Delegate?

    public init(url: URL? = nil, isDark: Bool = false) {
        self.requestedURL = url
        self.isDark = isDark
    }

    /// The web view, made — and pointed at `requestedURL` — the first time it is asked for.
    public var webView: WKWebView {
        if let madeWebView { return madeWebView }
        let configuration = WKWebViewConfiguration()
        // The shared, persistent store: a login to a dev server survives a relaunch, the way
        // it does in a browser. Per-project isolation is a choice to make later, on purpose.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        // Right-click ▸ Inspect Element. This is a developer's browser; the page being
        // debugged is usually the reason the pane is open.
        view.isInspectable = true
        applyTheme(to: view)
        let delegate = Delegate(session: self)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        self.delegate = delegate
        madeWebView = view
        observe(view)
        if let requestedURL { load(requestedURL, in: view) }
        return view
    }

    /// The web view if it has been made, without making it. For asking about the page — the
    /// canvas choosing where the keyboard goes — without starting a WebContent process.
    public var existingWebView: WKWebView? { madeWebView }

    // MARK: - Verbs

    /// Load what was typed. False, with `error` set, when it is not an address.
    @discardableResult
    public func open(text: String) -> Bool {
        guard let url = BrowserAddress.url(from: text) else {
            error = "“\(text.trimmingCharacters(in: .whitespaces))” is not an address"
            return false
        }
        open(url)
        return true
    }

    public func open(_ url: URL) {
        error = nil
        // The last page's title is not this page's. Kept, it stuck to the header until the
        // new page's arrived — and stuck for good when the new page had the same title,
        // because the title observer only reports a change.
        title = nil
        requestedURL = url
        if let madeWebView { load(url, in: madeWebView) }
        onChange?(url, nil)
    }

    public func reload() {
        guard let madeWebView else { return }
        error = nil
        // A page that failed to load has nothing to reload; go back to what was asked for.
        if madeWebView.url == nil, let requestedURL {
            load(requestedURL, in: madeWebView)
        } else {
            madeWebView.reload()
        }
    }

    public func stopLoading() { madeWebView?.stopLoading() }
    public func goBack() { madeWebView?.goBack() }
    public func goForward() { madeWebView?.goForward() }

    /// Hand the page to the system's default browser, for what a pane is not: extensions,
    /// a password manager, a second window.
    public func openInDefaultBrowser() {
        guard let url = madeWebView?.url ?? requestedURL else { return }
        NSWorkspace.shared.open(url)
    }

    public func focusAddress() { addressFocusRequest += 1 }

    public func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        if let madeWebView { applyTheme(to: madeWebView) }
        onChange?(requestedURL, title)
    }

    public func toggleDark() { setDark(!isDark) }

    /// Give the keyboard to the page itself.
    public func focusPage() {
        guard let madeWebView else { return }
        madeWebView.window?.makeFirstResponder(madeWebView)
    }

    /// For previews: show a page without a network.
    public func showHTML(_ html: String) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// The pane is closing. Stops the page, and with it any media, timers and sockets it
    /// was holding, rather than waiting for the web view to be deallocated.
    public func close() {
        observations = []
        madeWebView?.stopLoading()
        madeWebView?.navigationDelegate = nil
        madeWebView?.uiDelegate = nil
        madeWebView?.removeFromSuperview()
        madeWebView = nil
        delegate = nil
    }

    // MARK: - Web view plumbing

    /// The appearance first, so a page's own dark theme is in effect before the fallback
    /// decides whether it is needed. The script is installed for every future load and run
    /// on the current page, so the switch is immediate and survives navigation.
    private func applyTheme(to view: WKWebView) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        // What shows past the page's edges when it is rubber-banded, and during a load:
        // white behind a dark page is a flash on every navigation.
        view.underPageBackgroundColor = isDark ? NSColor(white: 0.1, alpha: 1) : .white
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Self.darkScript(isDark: isDark),
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        // A turn later, so the appearance change has reached the page's media queries
        // before the script looks at the page's colours.
        let dark = isDark
        DispatchQueue.main.async {
            view.evaluateJavaScript("window.__ultraSetDark && window.__ultraSetDark(\(dark))")
        }
    }

    /// The fallback for pages with no dark theme. A string here rather than a bundled
    /// resource: it is short, and a script loaded from a bundle is one more thing a build
    /// can be missing.
    ///
    /// A page counts as already dark when it says it supports a dark scheme, or when its
    /// background is dark once the appearance is — either way, inverting it would turn it
    /// back to light.
    static func darkScript(isDark: Bool) -> String {
        #"""
        (function () {
          var id = 'ultra-force-dark';
          function luminance(color) {
            var m = color && color.match(/rgba?\(([^)]+)\)/);
            if (!m) return null;
            var p = m[1].split(',').map(parseFloat);
            if (p.length > 3 && p[3] === 0) return null;
            return (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255;
          }
          function alreadyDark() {
            var meta = document.querySelector('meta[name="color-scheme"]');
            if (meta && /dark/.test(meta.content)) return true;
            var root = document.documentElement;
            if (/dark/.test(getComputedStyle(root).colorScheme || '')) return true;
            var nodes = [document.body, root];
            for (var i = 0; i < nodes.length; i++) {
              if (!nodes[i]) continue;
              var l = luminance(getComputedStyle(nodes[i]).backgroundColor);
              if (l !== null) return l < 0.4;
            }
            return false;
          }
          window.__ultraSetDark = function (on) {
            var style = document.getElementById(id);
            if (style) style.remove();
            if (!on || alreadyDark()) return;
            style = document.createElement('style');
            style.id = id;
            style.textContent =
              'html { filter: invert(1) hue-rotate(180deg); background: #fff; }' +
              'img, video, picture, canvas, iframe, embed, object, [style*="background-image"]' +
              ' { filter: invert(1) hue-rotate(180deg); }';
            (document.head || document.documentElement).appendChild(style);
          };
          window.__ultraSetDark(\#(isDark));
        })();
        """#
    }

    private func load(_ url: URL, in view: WKWebView) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// KVO rather than delegate callbacks for the state the chrome shows: `canGoBack` and
    /// friends change on things no delegate method reports, like a same-document
    /// `pushState` in a single-page app.
    private func observe(_ view: WKWebView) {
        func watch<Value>(_ path: KeyPath<WKWebView, Value>,
                          _ apply: @escaping @MainActor (BrowserSession, WKWebView) -> Void)
            -> NSKeyValueObservation {
            view.observe(path, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self, view)
                }
            }
        }
        observations = [
            watch(\.canGoBack) { $0.canGoBack = $1.canGoBack },
            watch(\.canGoForward) { $0.canGoForward = $1.canGoForward },
            watch(\.isLoading) { $0.isLoading = $1.isLoading },
            watch(\.estimatedProgress) { $0.progress = $1.estimatedProgress },
            watch(\.title) { session, view in
                let title = view.title.flatMap { $0.isEmpty ? nil : $0 }
                guard session.title != title else { return }
                session.title = title
                session.onChange?(session.requestedURL, title)
            },
            watch(\.url) { session, view in
                // Nil while a load is being set up, and for a page that failed. The last
                // real page is what should be remembered, not the gap between two.
                guard let url = view.url, url != session.requestedURL else { return }
                session.requestedURL = url
                session.onChange?(url, session.title)
            },
        ]
    }

    fileprivate func noteFailure(_ error: Error) {
        let nsError = error as NSError
        // A load replaced by another — a click during a load, a redirect — is not a failure.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // Frame load interrupted: WebKit's word for "this was a download, not a page".
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        self.error = Self.describe(nsError, url: requestedURL)
    }

    fileprivate func noteCommit() { error = nil }

    /// A sentence for the notice bar. The common case in this app is a dev server that is not
    /// running, and "Could not connect to the server." does not say which one.
    static func describe(_ error: NSError, url: URL?) -> String {
        let place = url.map(Self.place(of:))
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorCannotConnectToHost:
            return "Nothing is answering at \(place ?? "that address") — is the server running?"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Could not find \(place ?? "that host")"
        case NSURLErrorNotConnectedToInternet:
            return "Not connected to the internet"
        case NSURLErrorTimedOut:
            return "\(place ?? "The page") took too long to answer"
        default:
            return error.localizedDescription
        }
    }

    /// `localhost:3000`, `example.com`, or the whole URL for one with no host.
    static func place(of url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The web view's delegates. A separate object because `WKNavigationDelegate` is an
    /// `NSObjectProtocol`, and the session is an `@Observable` Swift class.
    @MainActor
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var session: BrowserSession?

        init(session: BrowserSession) { self.session = session }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            session?.noteCommit()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            session?.noteFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            session?.noteFailure(error)
        }

        /// `target="_blank"` and `window.open`. A pane has no second window to put the page
        /// in, so it opens here instead of nowhere — WebKit's default when this returns nil
        /// without loading anything.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
