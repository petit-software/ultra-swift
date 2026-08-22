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
            }
            TileFooter(isBusy: model.isRefreshing,
                       summary: "\(model.ports.count) listening") { await model.refresh() }
        }
        .background(Token.Colour.paneBackground)
        .tileHeaderInset()
        .task { await poll() }
    }

    /// Polled rather than watched: there is no notification for "a socket started
    /// listening". Two seconds is fast enough to catch a dev server starting and slow
    /// enough that `lsof` is not a background job.
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

            VStack(alignment: .leading, spacing: 1) {
                Text(port.command)
                    .font(Token.Type_.tileSubtitle)
                    .foregroundStyle(Token.Colour.label)
                Text("\(port.address) · pid \(port.pid)")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
            Spacer(minLength: 0)

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
