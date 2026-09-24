import Foundation

/// What was typed into a browser pane's address field, turned into something to load.
///
/// Pure, so the rules are unit-tested rather than discovered by typing into a web view. The
/// rules are the ones a developer's address bar needs, in this order:
///
/// - A full URL with a scheme loads as written: `https://…`, `http://…`, `file://…`.
/// - A local address gets HTTP, not HTTPS: `localhost:3000`, `127.0.0.1:8080`,
///   `myapp.local`, a bare LAN IP. A dev server almost never speaks TLS, and sending it
///   HTTPS is a blank page with a certificate error for what was really a typo-free address.
/// - Anything else that looks like a host — it has a dot and no spaces — gets HTTPS.
/// - Anything that does not look like an address at all is refused. There is no search
///   engine behind this field: a pane that quietly sent what you typed to a third party is
///   a surprise, and in a terminal app the typed text is as likely to be a path or a secret
///   as a query.
public enum BrowserAddress {

    /// The URL to load, or nil when the text is not an address.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        // Already has a scheme. `localhost:3000` also parses with a "scheme" of `localhost`,
        // which is why only the schemes a pane can actually load count here.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return scheme == "file" || scheme == "about" || url.host != nil ? url : nil
        }

        // An absolute path is a file on this machine.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: path)
        }

        let host = hostPart(of: trimmed)
        guard !host.isEmpty else { return nil }
        let scheme: String
        if isLocal(host) {
            scheme = "http"
        } else if host.contains(".") {
            scheme = "https"
        } else {
            return nil
        }
        guard let url = URL(string: "\(scheme)://\(trimmed)"), url.host != nil else { return nil }
        return url
    }

    /// The host of an address with no scheme: everything before the first `/`, `?` or `#`,
    /// without a port.
    static func hostPart(of text: String) -> String {
        let end = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        let authority = text[..<end]
        // IPv6 literals keep their colons inside the brackets.
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            return String(authority[...close]).lowercased()
        }
        return String(authority.split(separator: ":", maxSplits: 1).first ?? "").lowercased()
    }

    /// Addresses that are this machine or this network, which get plain HTTP.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let numbers = octets.compactMap { UInt8($0) }
        guard numbers.count == 4 else { return false }
        // Loopback, and the three private ranges a phone or a second Mac on the desk sits in.
        switch (numbers[0], numbers[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (0, 0) where numbers[2] == 0 && numbers[3] == 0: return true
        default: return false
        }
    }

    /// What the field shows for a loaded page: the URL without a trailing slash on a bare
    /// host, so `http://localhost:3000/` reads back as it was typed.
    public static func display(_ url: URL) -> String {
        let text = url.absoluteString
        if url.path == "/", url.query == nil, url.fragment == nil, text.hasSuffix("/") {
            return String(text.dropLast())
        }
        return text
    }
}
