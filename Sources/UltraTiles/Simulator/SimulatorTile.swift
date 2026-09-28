import AppKit
import SwiftUI
import UltraDesign
import UltraSimulator

/// A simulator in a pane: the device picker on top, its screen in the middle — live, with
/// the pointer as a finger — and the footer every tile has.
///
/// For the app the agent just built. Not the Simulator app: one device per pane, and a
/// second device is a second pane. The screen is the CONTENT layer, opaque like terminal
/// text; the chrome around it is the tile's own.
public struct SimulatorTile: View {
    let context: TileContext
    let session: SimulatorSession

    public init(context: TileContext, session: SimulatorSession) {
        self.context = context
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            devicePicker
            if let error = session.error {
                NoticeBar(symbol: "exclamationmark.triangle.fill", message: error,
                          tint: Color.orange.opacity(0.18),
                          dismiss: { session.error = nil }) { EmptyView() }
            }
            screen
        }
        .tileFooter { footer }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    /// The device, in the composer's capsule where the browser keeps its address — the one
    /// place a tile shows what it is pointed at. Click for the list, grouped by runtime.
    private var devicePicker: some View {
        HStack(spacing: 6) {
            Image(systemName: session.device?.isTablet == true ? "ipad" : "iphone")
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(session.device?.name ?? "Choose a simulator")
                .font(Token.Type_.body)
                .foregroundStyle(session.device == nil ? Token.Colour.tertiaryLabel : Token.Colour.label)
                .lineLimit(1)
            if let device = session.device, !device.runtime.isEmpty {
                Text(device.runtimeName)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(Token.Colour.tertiaryLabel)
                Text(device.state.rawValue)
                    .font(Token.Type_.monoSmall)
                    .foregroundStyle(device.state.isBooted ? Color.green : Token.Colour.tertiaryLabel)
            }
            Spacer(minLength: 0)
            ChromeMenuButton(symbol: "chevron.up.chevron.down", help: "Choose Device",
                             size: 18, entries: deviceEntries)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous).fill(Token.Colour.label.opacity(0.06))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Device: \(session.device?.name ?? "none chosen")")
    }

    private func deviceEntries() -> [ChromeMenuEntry] {
        guard !session.devices.isEmpty else {
            return [.caption(session.hasXcode ? "No simulators — create one in Xcode"
                                              : "Xcode is not installed")]
        }
        var entries: [ChromeMenuEntry] = []
        for group in SimulatorDeviceList.grouped(session.devices) {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.caption(SimulatorDevice.runtimeName(of: group.runtime)))
            for device in group.devices {
                entries.append(.item(title: device.state.isBooted ? "\(device.name) — booted" : device.name,
                                     symbol: device.isTablet ? "ipad" : "iphone",
                                     isOn: device.udid == session.udid,
                                     isEnabled: device.isAvailable) { session.choose(device) })
            }
        }
        return entries
    }

    @ViewBuilder
    private var screen: some View {
        if session.device == nil {
            emptyState(symbol: "iphone", title: "Choose a simulator above",
                       detail: session.hasXcode ? "New Simulator Pane ⌥⌘P" : "Xcode is not installed")
        } else if !session.isBooted, !session.isBusy {
            emptyState(symbol: "iphone.slash", title: "\(session.device?.name ?? "The device") is shut down",
                       detail: "Boot it from the footer")
        } else {
            ZStack(alignment: .bottom) {
                SimulatorScreenView(session: session)
                if let liveError = session.liveError, session.isBooted {
                    Text("Not live: \(liveError)")
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Token.Colour.label.opacity(0.08)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
                if session.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
        }
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text(title)
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.secondaryLabel)
            Text(detail)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Power leads, then the device's buttons, then what to do with the screen. Each is
    /// also on Pane ▸ Simulator, so none is pointer-only.
    private var footer: some View {
        TileFooter(summary: session.isLive ? "live" : (session.isBooted ? "screenshot" : ""),
                   summaryHelp: session.liveError) {
            if session.isBooted {
                TileFooterButton(symbol: "power", help: "Shut Down",
                                 isEnabled: !session.isBusy) { session.shutdown() }
            } else {
                TileFooterButton(symbol: "power", help: "Boot",
                                 isEnabled: session.device != nil && !session.isBusy) { session.boot() }
            }
            TileFooterButton(symbol: "house", help: "Home (⇧⌘H)",
                             isEnabled: session.canPress) { session.pressHome() }
            TileFooterButton(symbol: "lock", help: "Lock",
                             isEnabled: session.canPress) { session.pressLock() }
            TileFooterButton(symbol: "camera", help: "Screenshot — saved to .ultra/screenshots and sent to the shell",
                             isEnabled: session.isBooted) {
                Task { await session.takeScreenshot() }
            }
            TileFooterButton(symbol: session.appearance == .dark ? "sun.max" : "moon",
                             help: "Toggle Dark Appearance on the device",
                             isEnabled: session.isBooted) { session.toggleAppearance() }
            TileFooterButton(symbol: "link", help: "Open URL on Device…",
                             isEnabled: session.isBooted) { askForURL() }
        }
    }

    private func askForURL() {
        let alert = NSAlert()
        alert.messageText = "Open URL on \(session.device?.name ?? "the device")"
        alert.informativeText = "A web address or an app's URL scheme."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://… or myapp://…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)),
              url.scheme != nil else { return }
        session.open(url)
    }
}

/// The session's screen view, placed in the tile.
///
/// The SAME view every time, because the session owns it: a pane rebuilt for any reason
/// keeps its layer and its connection.
struct SimulatorScreenView: NSViewRepresentable {
    let session: SimulatorSession

    func makeNSView(context: Context) -> SimulatorDisplayView {
        let view = session.displayView
        view.onClick = { [weak view] in view?.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: SimulatorDisplayView, context: Context) {}
}

/// The simulator pane's content: the tile, hosted, with one opinion about the keyboard.
///
/// A focused pane on a live device gives the keyboard to the SCREEN, so typing lands in
/// the device. Anything else leaves the choice to the canvas.
final class SimulatorHostingView: NSHostingView<SimulatorTile>, KeyboardTargetProviding {
    private let session: SimulatorSession

    init(tile: SimulatorTile, session: SimulatorSession) {
        self.session = session
        super.init(rootView: tile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @available(*, unavailable)
    required init(rootView: SimulatorTile) { fatalError("use init(tile:session:)") }

    var preferredKeyboardTarget: NSView? {
        session.isLive ? session.existingDisplayView : nil
    }
}

// MARK: - Previews

#Preview("Simulator — live fixture", traits: .fixedLayout(width: 420, height: 760)) {
    let session = SimulatorSession.preview(booted: true)
    SimulatorTile(context: .inert(), session: session)
}

#Preview("Simulator — shut down", traits: .fixedLayout(width: 420, height: 500)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.preview(booted: false))
}

#Preview("Simulator — none chosen", traits: .fixedLayout(width: 420, height: 400)) {
    SimulatorTile(context: .inert(), session: SimulatorSession())
}

extension SimulatorSession {
    /// A session on a made-up device with a drawn screen, for previews. No Xcode, no poll.
    static func preview(booted: Bool) -> SimulatorSession {
        let session = SimulatorSession()
        let device = SimulatorDevice(udid: "PREVIEW", name: "iPhone 17",
                                     runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                     state: booted ? .booted : .shutdown,
                                     deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        session.adoptForPreview(devices: [device,
                                          SimulatorDevice(udid: "PREVIEW-2", name: "iPad mini (A17 Pro)",
                                                          runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                                                          state: .shutdown)],
                                device: device, still: booted ? Self.drawnScreen() : nil)
        return session
    }

    private static func drawnScreen() -> CGImage? {
        let size = CGSize(width: 1206, height: 2622)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.10, green: 0.11, blue: 0.20, alpha: 1),
                      CGColor(red: 0.35, green: 0.30, blue: 0.60, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        for row in 0..<4 {
            for column in 0..<4 {
                let rect = CGRect(x: 90 + column * 270, y: Int(size.height) - 500 - row * 300, width: 180, height: 180)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil))
            }
        }
        context.fillPath()
        return context.makeImage()
    }
}
