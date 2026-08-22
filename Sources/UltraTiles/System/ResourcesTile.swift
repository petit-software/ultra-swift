import SwiftUI
import UltraDesign

/// What this workspace's own processes are costing.
public struct ResourcesTile: View {
    @State private var model = ResourcesModel()
    private let context: TileContext

    public init(context: TileContext) { self.context = context }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if model.processes.isEmpty {
                EmptyTileState(icon: "gauge.with.dots.needle.33percent",
                               title: "No processes yet",
                               detail: "Started by this workspace's shells")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.processes) { process in ProcessRow(process: process) }
                    }
                    .padding(.vertical, 4)
                }
            }
            TileFooter(isBusy: model.isRefreshing,
                       summary: "\(model.processes.count) processes") { await model.refresh() }
        }
        .background(Token.Colour.paneBackground)
        .tileHeaderInset()
        .task { await poll() }
    }

    /// The headline: one number, one shape. The number is the reading; the sparkline is the
    /// trend. Neither needs an axis to do its job at this size.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(model.totalCPU.latest))%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Token.Colour.label)
                    .monospacedDigit()
                Text("CPU · \(Int(model.totalMemory)) MB")
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
            }
            Sparkline(samples: model.totalCPU)
                .frame(height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func poll() async {
        while !Task.isCancelled {
            model.rootPIDs = context.shellPIDs()
            await model.refresh()
            await TilePolling.tick(Preferences.resourcesInterval)
        }
    }
}

private struct ProcessRow: View {
    let process: ResourcesModel.Process

    var body: some View {
        HStack(spacing: 8) {
            Text(process.command)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Sparkline(samples: process.history)
                .frame(width: 48, height: 14)
            Text("\(process.cpu, specifier: "%.1f")%")
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.secondaryLabel)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Text("\(Int(process.memory))M")
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Shared tile furniture

struct EmptyTileState: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text(title)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.secondaryLabel)
            if let detail {
                Text(detail)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TileFooter: View {
    let isBusy: Bool
    let summary: String
    let refresh: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(isBusy ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(isBusy)
            Spacer()
            Text(summary)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.tertiaryLabel)
        }
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

#Preview("Resources", traits: .fixedLayout(width: 340, height: 320)) {
    ResourcesTile(context: .inert())
}
