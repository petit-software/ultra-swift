import Foundation

/// The colour-scheme half of the terminal protocol that SwiftTerm does not speak.
///
/// A program that draws its own surfaces — an agent's composer, an editor's status line —
/// picks their colours from the terminal's background, which it asks for once, at launch
/// (OSC 11). Switch the pane from dark to light after that and the pane repaints while the
/// program keeps the colours it chose for the old one: a dark composer on a light pane,
/// with the text typed into it drawn in the pane's new, dark, default foreground.
///
/// The fix is the protocol contour, Ghostty, kitty and others agreed on, and the one
/// Claude Code, Neovim and Helix listen to:
///
///     CSI ? 2031 h      tell me when the scheme changes
///     CSI ? 2031 l      stop telling me
///     CSI ? 996 n       which is it now?
///     CSI ? 997 ; 1 n   the answer, and the notification: dark
///     CSI ? 997 ; 2 n   … light
///
/// SwiftTerm drops all three requests as unknown, and has no hook for an unknown CSI, so
/// they are read here, from the same bytes on their way in. Nothing is taken out of the
/// stream: SwiftTerm still sees the sequences and still ignores them.
public enum ColorSchemeReports {

    public enum Request: Equatable, Sendable {
        /// `CSI ? 2031 h` / `l` — subscribe to changes, or stop.
        case notify(Bool)
        /// `CSI ? 996 n` — report the scheme once, now.
        case query
    }

    /// `CSI ? 997 ; 1 n` for dark, `; 2 n` for light.
    public static func report(isDark: Bool) -> [UInt8] {
        Array("\u{1b}[?997;\(isDark ? 1 : 2)n".utf8)
    }

    /// Finds the requests in a program's output.
    ///
    /// Stateful, because a read from a PTY ends wherever the kernel's buffer did and a
    /// sequence is routinely split across two of them. The state is a handful of bytes:
    /// only a CSI's parameters are kept, and only until its final byte.
    public struct Scanner: Sendable {
        private enum State: Sendable { case ground, escape, csi }
        private var state = State.ground
        private var parameters: [UInt8] = []
        /// Set when a CSI carries an intermediate byte or runs long: it is then not one of
        /// ours — `CSI ? 2031 $ p` is DECRQM, a different question — and is skipped whole.
        private var isForeign = false

        /// Longer than any sequence this cares about, with room for a program that sets
        /// several modes in one (`CSI ? 1004 ; 2004 ; 2031 h`).
        private static let parameterLimit = 64

        public init() {}

        public mutating func scan<Bytes: Sequence>(_ bytes: Bytes) -> [Request]
        where Bytes.Element == UInt8 {
            var requests: [Request] = []
            for byte in bytes {
                switch state {
                case .ground:
                    if byte == 0x1b { state = .escape }
                case .escape:
                    if byte == UInt8(ascii: "[") {
                        state = .csi
                        parameters.removeAll(keepingCapacity: true)
                        isForeign = false
                    } else if byte != 0x1b {
                        state = .ground
                    }
                case .csi:
                    switch byte {
                    case 0x30...0x3f:
                        if parameters.count < Self.parameterLimit {
                            parameters.append(byte)
                        } else {
                            isForeign = true
                        }
                    case 0x20...0x2f:
                        isForeign = true
                    case 0x40...0x7e:
                        if !isForeign, let request = Self.request(parameters, final: byte) {
                            requests.append(contentsOf: request)
                        }
                        state = .ground
                    case 0x1b:
                        state = .escape
                    default:
                        // A C0 control inside a CSI is executed and the sequence carries
                        // on (ECMA-48); CAN and SUB abandon it.
                        if byte == 0x18 || byte == 0x1a { state = .ground }
                    }
                }
            }
            return requests
        }

        private static func request(_ parameters: [UInt8], final: UInt8) -> [Request]? {
            guard parameters.first == UInt8(ascii: "?") else { return nil }
            let modes = parameters.dropFirst().split(separator: UInt8(ascii: ";"),
                                                     omittingEmptySubsequences: false)
            switch final {
            case UInt8(ascii: "h"), UInt8(ascii: "l"):
                guard modes.contains(where: { $0.elementsEqual("2031".utf8) }) else { return nil }
                return [.notify(final == UInt8(ascii: "h"))]
            case UInt8(ascii: "n"):
                guard modes.count == 1, modes[0].elementsEqual("996".utf8) else { return nil }
                return [.query]
            default:
                return nil
            }
        }
    }
}
