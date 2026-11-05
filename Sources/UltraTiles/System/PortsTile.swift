import AppKit
import SwiftUI
import UltraDesign

/// What is listening, and who owns it.
public struct PortsTile: View {
    /// Held by the factory rather than in `@State`, so a menu command can reach the
    /// pane's filter (`TileFactory.portsModel`).
    private let model: PortsModel
    private let context: TileContext

    public init(context: TileContext, model: PortsModel = PortsModel()) {
        self.context = context
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.ports.isEmpty {
                EmptyTileState(icon: "network", title: "Nothing listening")
            } else if model.visiblePorts.isEmpty {
                EmptyTileState(icon: "line.3.horizontal.decrease.circle",
                               title: "Nothing listening on \(model.addressFilter.phrase)")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visiblePorts) { port in
                            PortRow(port: port, model: model, openInBrowser: context.openInBrowser)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tileScrollBar()
            }
        }
        .tileFooter { footer }
        .task { await poll() }
    }

    /// Polled rather than watched: there is no notification for "a socket started
    /// listening". Two seconds is fast enough to catch a dev server starting and slow
    /// enough that `lsof` is not a background job.
    private var footer: some View {
        TileFooter(summary: summary) {
            TileFooterButton(symbol: "arrow.clockwise", help: "Refresh now",
                             isEnabled: !model.isRefreshing) {
                Task { await model.refresh() }
            }
            // Accent while filtered, so a short list says why it is short.
            ChromeMenuButton(symbol: "line.3.horizontal.decrease.circle",
                             help: "Filter by address",
                             tint: model.addressFilter == .all ? nil : Token.Colour.accentInk) {
                filterEntries
            }
        }
    }

    private var summary: String {
        model.addressFilter == .all
            ? "\(model.ports.count) listening"
            : "\(model.visiblePorts.count) of \(model.ports.count) listening · \(model.addressFilter.phrase)"
    }

    /// The three groups, which are also on Pane ▸ Ports, then each address in use.
    private var filterEntries: [ChromeMenuEntry] {
        var entries: [ChromeMenuEntry] = [PortsAddressFilter.all, .loopback, .anyInterface].map { filter in
            .item(title: filter.title, isOn: model.addressFilter == filter) { model.addressFilter = filter }
        }
        let addresses = model.addresses
        if !addresses.isEmpty {
            entries.append(.separator)
            entries.append(.caption("Address"))
            for address in addresses {
                let filter = PortsAddressFilter.exact(address)
                entries.append(.item(title: address, isOn: model.addressFilter == filter) {
                    model.addressFilter = filter
                })
            }
        }
        return entries
    }

    private func poll() async {
        while !Task.isCancelled {
            model.ownedPIDs = context.shellPIDs()
            await model.refresh()
            await TilePolling.tick(Preferences.portsInterval)
        }
    }
}

private struct PortRow: View {
    let port: PortsModel.Port
    let model: PortsModel
    /// Into a browser pane beside the shell, which is where a dev server's page is wanted
    /// most of the time. The system browser is the button beside it.
    var openInBrowser: (URL) -> Void = { _ in }
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(port.port))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(port.isOurs ? Token.Colour.accentInk : Token.Colour.label)
                .frame(minWidth: 44, alignment: .leading)

            Text(port.command)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.label)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Opposite side rather than underneath, and at the SAME size as the command it
            // sits beside — the two are one fact ("node, on 127.0.0.1, pid 4213") and
            // shrinking half of it made the row look like a heading with a caption. Rank is
            // carried by colour alone, which is the quieter signal and the one that survives
            // a row being read at a glance.
            //
            // Covered by the actions on hover rather than swapped out for them: the row keeps
            // its shape and the command keeps its truncation point. A tile is ~340pt wide;
            // three buttons and an address both fitting means the command — the thing being
            // looked FOR — is what gets truncated to make room.
            Text("\(port.address) · pid \(port.pid)")
                .font(Token.Type_.tileSubtitle.monospacedDigit())
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .lineLimit(1)
                // Never the side that truncates: losing the tail of this costs the pid,
                // which is the number the SIGTERM button acts on.
                .layoutPriority(1)
        }
        // Floating over the address — see `tileHoverControls`.
        .tileHoverControls(isHovering) {
            HStack(spacing: 8) {
                if let url = port.url {
                    Button { openInBrowser(url) } label: {
                        Image(systemName: "globe")
                    }
                    .help("Open localhost:\(port.port) in a Browser pane")
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help("Open http://localhost:\(port.port) in the default browser")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(port.port), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy port")
                Button { model.terminate(port) } label: { Image(systemName: "stop.circle") }
                    .help("Send SIGTERM to pid \(port.pid)")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Token.Colour.tertiaryLabel)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

#Preview("Ports", traits: .fixedLayout(width: 340, height: 300)) {
    PortsTile(context: .inert())
}
