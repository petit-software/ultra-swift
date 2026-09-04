import Foundation

/// One server-sent event, as the three HTTP services deliver their streams.
public struct ServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String? = nil, data: String) {
        self.event = event
        self.data = data
    }
}

/// Turns the lines of an SSE body into events.
///
/// Written as a line-at-a-time state machine rather than over the whole body, because the
/// body never ends until the answer does — the parser is fed as bytes arrive and hands
/// back an event every time a blank line closes one. Multi-line `data:` fields are joined
/// with newlines, per the spec; comments (`:` lines) and unknown fields are dropped.
public struct SSEParser: Sendable {
    private var event: String?
    private var data: [String] = []

    public init() {}

    /// Feed one line, without its terminator. Returns the event this line completed, if it
    /// was the blank line that completes one.
    public mutating func feed(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { event = nil; data = [] }
            guard !data.isEmpty else { return nil }
            return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value) = split(line)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    /// The end of the body. A final event with no trailing blank line is still an event.
    public mutating func finish() -> ServerSentEvent? {
        feed("")
    }

    /// `name: value` — one optional space after the colon is not part of the value.
    private func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[..<colon])
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") { value = value.dropFirst() }
        return (field, String(value))
    }
}
