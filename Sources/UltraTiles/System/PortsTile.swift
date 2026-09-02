import AppKit
import SwiftUI
import UltraDesign

/// What is listening, and who owns it.
public struct PortsTile: View {
    @State private var model = PortsModel()
    private let context: TileContext

    public init(context: TileContext) { self.context = context }

    public var body: some View {
        VStack(spacing: 0) {
            if model.ports.isEmpty {
                EmptyTileState(icon: "network",
                               title: "Nothing listening",
                               detail: model.lastError)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.ports) { port in PortRow(port: port, model: model) }
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
        TileFooter(summary: "\(model.ports.count) listening") {
            TileFooterButton(symbol: "arrow.clockwise", help: "Refresh now",
                             isEnabled: !model.isRefreshing) {
                Task { await model.refresh() }
            }
        }
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
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(port.port))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(port.isOurs ? Token.Colour.accent : Token.Colour.label)
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
            // Given up to the actions on hover instead of squeezing alongside them. A tile is
            // ~340pt wide; three buttons and an address both fitting means the command — the
            // thing being looked FOR — is what gets truncated to make room.
            if isHovering {
                if let url = port.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "safari")
                    }
                    .help("Open http://localhost:\(port.port)")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(port.port), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy port")
                Button { model.terminate(port) } label: { Image(systemName: "stop.circle") }
                    .help("Send SIGTERM to pid \(port.pid)")
            } else {
                Text("\(port.address) · pid \(port.pid)")
                    .font(Token.Type_.tileSubtitle.monospacedDigit())
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .lineLimit(1)
                    // Never the side that truncates: losing the tail of this costs the pid,
                    // which is the number the SIGTERM button acts on.
                    .layoutPriority(1)
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
