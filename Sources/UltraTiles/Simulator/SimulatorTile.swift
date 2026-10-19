import AppKit
import SwiftUI
import UltraDesign
import UltraSimulator

/// A simulator in a pane: the device in the middle — live, in its own enclosure, with the
/// pointer as a finger — the device's buttons floating beside it while it runs, and the
/// footer every tile has.
///
/// For the app the agent just built. Not the Simulator app: one device per pane, and a
/// second device is a second pane. The screen is the CONTENT layer, opaque like terminal
/// text; the chrome around it is the tile's own.
///
/// Two kinds of control, in two places. What the device IS — which one, on or off, how
/// large, light or dark, a URL to open — is the pane's business, and sits in the footer
/// with every other tile's. What you do TO a running device — press Home, lock it, take
/// its picture, fold it, turn it — is the device's, and floats beside it only while it
/// runs, so a shut-down device offers nothing it cannot do.
public struct SimulatorTile: View {
    let context: TileContext
    let session: SimulatorSession
    /// For previews and tests: the floating controls as if the pointer were over the
    /// device, with ⌥ held or not. Nil follows the pointer and the keyboard.
    var reveal: Reveal?

    public enum Reveal: Sendable { case controls, rotation }

    @State private var isHovering = false
    @State private var option = OptionKeyWatcher()

    public init(context: TileContext, session: SimulatorSession) {
        self.context = context
        self.session = session
    }

    init(context: TileContext, session: SimulatorSession, reveal: Reveal?) {
        self.context = context
        self.session = session
        self.reveal = reveal
    }

    public var body: some View {
        screen
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tileToast(session.error.map(TileNotice.unreachable), dismiss: { session.error = nil })
            .tileFooter { footer }
            .onAppear {
                session.start()
                option.start()
            }
            .onDisappear {
                session.stop()
                option.stop()
            }
    }

    // MARK: - The screen

    @ViewBuilder
    private var screen: some View {
        if session.device == nil {
            emptyState(symbol: "iphone", title: "No simulator chosen",
                       detail: session.hasXcode ? "or from the device menu in the footer" : "Xcode is not installed") {
                if session.hasXcode { chooseButton }
            }
        } else if !session.isBooted, !session.isBusy {
            emptyState(symbol: "iphone.slash", title: "\(session.device?.name ?? "The device") is shut down",
                       detail: "Pane ▸ Simulator ▸ Boot Device") {
                Button("Boot") { session.boot() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
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
                if session.isBusy || session.isMoving {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                }
            }
            .overlay(alignment: .trailing) {
                if showsControls {
                    deviceControls
                        .padding(.trailing, 10)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsHint {
                    optionHint
                        .padding(10)
                        .transition(.opacity)
                }
            }
            .onHover { isHovering = $0 }
            .animation(Token.Environment_.reduceMotion ? nil : Token.Motion.chromeFade, value: showsControls)
            .animation(Token.Environment_.reduceMotion ? nil : Token.Motion.chromeFade, value: showsRotation)
        }
    }

    // MARK: - Floating controls

    /// The device's buttons show while the pointer is over the pane, or while ⌥ is held
    /// with the keyboard on the device — and only while it runs.
    private var showsControls: Bool {
        guard session.isBooted else { return false }
        if let reveal { return reveal == .controls || reveal == .rotation }
        return isHovering || (option.isDown && screenHasKeyboard)
    }

    /// ⌥ adds the quarter turns: the device's buttons are pressed often, a turn now and
    /// then, and two more glyphs in the pill all the time would be noise.
    private var showsRotation: Bool {
        guard showsControls else { return false }
        if let reveal { return reveal == .rotation }
        return option.isDown
    }

    /// The hint in the corner, while hovering without ⌥, that ⌥ does something.
    private var showsHint: Bool { showsControls && !showsRotation && reveal == nil }

    private var screenHasKeyboard: Bool {
        guard let view = session.existingDisplayView else { return false }
        return view.window?.firstResponder === view
    }

    /// One pill of glass, stood on its end at the pane's trailing edge — beside a portrait
    /// device, which leaves room there, and never across the bottom of the screen, where
    /// the home indicator takes its swipes.
    private var deviceControls: some View {
        VStack(spacing: 2) {
            if showsRotation {
                floating("rotate.left", help: "Rotate Left (⌃⌥⌘←)", isEnabled: session.canMove) {
                    session.rotateLeft()
                }
                floating("rotate.right", help: "Rotate Right (⌃⌥⌘→)", isEnabled: session.canMove) {
                    session.rotateRight()
                }
                Rectangle()
                    .fill(Token.Colour.separator)
                    .frame(width: 14, height: 1)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
            }
            floating("house", help: "Home (⇧⌘H)", isEnabled: session.canPress) { session.pressHome() }
            floating("lock", help: "Lock", isEnabled: session.canPress) { session.pressLock() }
            floating("camera", help: "Screenshot — saved to .ultra/screenshots and sent to the shell",
                     isEnabled: session.isBooted) {
                Task { await session.takeScreenshot() }
            }
            if session.isFoldable {
                floating(session.isOpen ? "book.closed" : "book",
                         help: session.isOpen ? "Fold (⌃⌥⌘F)" : "Unfold (⌃⌥⌘F)",
                         isEnabled: session.canMove) { session.toggleFold() }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .foregroundStyle(Token.Colour.label)
        .tileHoverPill()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Device controls")
    }

    private func floating(_ symbol: String, help: String, isEnabled: Bool,
                          action: @escaping () -> Void) -> some View {
        ChromeIconButton(symbol: symbol, help: help, isEnabled: isEnabled, action: action)
    }

    private var optionHint: some View {
        HStack(spacing: 4) {
            Text("⌥")
                .font(.system(size: 12, weight: .semibold))
            Text("Rotate")
                .font(Token.Type_.monoSmall)
        }
        .foregroundStyle(Token.Colour.secondaryLabel)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .tileHoverPill()
        .allowsHitTesting(false)
        .accessibilityLabel("Hold Option to rotate the device")
    }

    // MARK: - Empty states

    private func emptyState<Action: View>(symbol: String, title: String, detail: String,
                                          @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Token.Colour.tertiaryLabel)
            Text(title)
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.secondaryLabel)
            action()
            Text(detail)
                .font(Token.Type_.monoSmall)
                .foregroundStyle(Token.Colour.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseButton: some View {
        ChromeMenuTrigger(help: "Choose Simulator", entries: deviceEntries) { isHovering in
            Text("Choose Simulator…")
                .font(Token.Type_.body)
                .foregroundStyle(Token.Colour.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(Token.Colour.label.opacity(isHovering ? 0.12 : 0.07)))
        }
    }

    // MARK: - Footer

    /// The device leads, because it is what the rest act on; then power, then what to do
    /// with the screen. Each is also on Pane ▸ Simulator, so none is pointer-only.
    private var footer: some View {
        TileFooter(summary: footerSummary, summaryHelp: session.liveError) {
            deviceMenu
            if session.isBooted {
                TileFooterButton(symbol: "power", help: "Shut Down",
                                 isEnabled: !session.isBusy) { session.shutdown() }
            } else {
                TileFooterButton(symbol: "power", help: "Boot",
                                 isEnabled: session.device != nil && !session.isBusy) { session.boot() }
            }
            TileFooterButton(symbol: "link", help: "Open URL on Device…",
                             isEnabled: session.isBooted) { askForURL() }
            TileFooterButton(symbol: "minus.magnifyingglass", help: "Zoom Out on Device (⌃⌘-)",
                             isEnabled: session.device != nil && session.canZoomOut) { session.zoomOut() }
            TileFooterButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Fit Device to Pane (⌃⌘0)",
                             isEnabled: session.device != nil && !session.isFitted) { session.zoomToFit() }
            TileFooterButton(symbol: "plus.magnifyingglass", help: "Zoom In on Device (⌃⌘=)",
                             isEnabled: session.device != nil && session.canZoomIn) { session.zoomIn() }
            // Last, after the line, as in every footer — see `TileFooterSeparator`. The
            // device's appearance rather than the pane's, but it is the same sun and moon.
            TileFooterSeparator()
            TileFooterButton(symbol: session.appearance == .dark ? "sun.max" : "moon",
                             help: "Toggle Dark Appearance on the device",
                             isEnabled: session.isBooted) { session.toggleAppearance() }
        }
    }

    /// The device, by name, as the footer's first control: press it for every simulator on
    /// the Mac. Small and quiet — the pane's header already says which device this is, in
    /// large type; this is where it is CHANGED.
    private var deviceMenu: some View {
        ChromeMenuTrigger(help: "Choose Simulator", entries: deviceEntries) { isHovering in
            HStack(spacing: 4) {
                Image(systemName: session.device?.isTablet == true ? "ipad" : "iphone")
                    .font(.system(size: 12))
                Text(session.device?.name ?? "Choose Simulator")
                    .font(Token.Type_.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isHovering ? Token.Colour.label : Token.Colour.secondaryLabel)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Token.Colour.label.opacity(isHovering ? 0.08 : 0)))
        }
        .padding(.trailing, 2)
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
        entries.append(.separator)
        entries.append(.item(title: "Show Device Frame", symbol: "iphone.gen3", isOn: session.showsFrame) {
            session.toggleFrame()
        })
        return entries
    }

    /// The runtime, what the screen is — live, or a screenshot — and, once zoomed, how
    /// large: "iOS 27.1 · live · 150%". Scrolling pans a device larger than the pane; a
    /// pinch zooms.
    private var footerSummary: String {
        guard let device = session.device else { return "" }
        var parts: [String] = []
        if !device.runtime.isEmpty { parts.append(device.runtimeName) }
        if session.isBusy {
            parts.append(device.state.isBooted ? "shutting down" : "booting")
        } else if session.isBooted {
            parts.append(session.isLive ? "live" : "screenshot")
        }
        if session.isFoldable, session.isBooted { parts.append(session.isOpen ? "open" : "folded") }
        if !session.isFitted { parts.append(session.zoomLabel) }
        return parts.joined(separator: " · ")
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

/// Whether ⌥ is held, from a local event monitor rather than SwiftUI's modifier
/// observation: a focused screen takes `flagsChanged` itself, to hand the key to the
/// device, so nothing above it in the responder chain would hear ⌥ go down.
@MainActor
@Observable
final class OptionKeyWatcher {
    private(set) var isDown = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resign: NSObjectProtocol?

    func start() {
        guard monitor == nil else { return }
        isDown = NSEvent.modifierFlags.contains(.option)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let down = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.isDown = down }
            return event
        }
        // A ⌥ let go in another app never arrives here.
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDown = false }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        monitor = nil
        resign = nil
        isDown = false
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

#Preview("Simulator — pointer over the device", traits: .fixedLayout(width: 420, height: 760)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.preview(booted: true), reveal: .controls)
}

#Preview("Simulator — ⌥ held", traits: .fixedLayout(width: 420, height: 760)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.preview(booted: true), reveal: .rotation)
}

#Preview("Simulator — turned on its side", traits: .fixedLayout(width: 760, height: 420)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.preview(booted: true, angle: 270))
}

#Preview("Simulator — iPhone Duo, folded", traits: .fixedLayout(width: 460, height: 640)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.previewDuo(open: false), reveal: .controls)
}

#Preview("Simulator — iPhone Duo, open", traits: .fixedLayout(width: 760, height: 560)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.previewDuo(open: true), reveal: .rotation)
}

#Preview("Simulator — zoomed in", traits: .fixedLayout(width: 420, height: 760)) {
    let session = SimulatorSession.preview(booted: true)
    session.zoomIn(); session.zoomIn()
    return SimulatorTile(context: .inert(), session: session)
}

#Preview("Simulator — shut down", traits: .fixedLayout(width: 420, height: 500)) {
    SimulatorTile(context: .inert(), session: SimulatorSession.preview(booted: false))
}

#Preview("Simulator — none chosen", traits: .fixedLayout(width: 420, height: 400)) {
    SimulatorTile(context: .inert(), session: SimulatorSession())
}

extension SimulatorSession {
    private static let previewRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-27-1"

    /// A session on a made-up device with a drawn screen, for previews. No Xcode, no poll.
    static func preview(booted: Bool, angle: Double = 0) -> SimulatorSession {
        let session = SimulatorSession()
        let device = SimulatorDevice(udid: "PREVIEW", name: "iPhone 17", runtime: previewRuntime,
                                     state: booted ? .booted : .shutdown,
                                     deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        session.adoptForPreview(devices: [device,
                                          SimulatorDevice(udid: "PREVIEW-2", name: "iPad mini (A17 Pro)",
                                                          runtime: previewRuntime, state: .shutdown)],
                                device: device,
                                still: booted ? Self.drawnScreen(CGSize(width: 1206, height: 2622)) : nil,
                                angle: angle)
        return session
    }

    /// iPhone Duo, on its cover screen or opened onto the wide inner one, which the
    /// hardware mounts on its side.
    static func previewDuo(open: Bool) -> SimulatorSession {
        let session = SimulatorSession()
        let device = SimulatorDevice(udid: "PREVIEW-DUO", name: "iPhone Duo", runtime: previewRuntime,
                                     state: .booted,
                                     deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo")
        let screen = open ? CGSize(width: 2007, height: 2853) : CGSize(width: 1398, height: 2034)
        session.adoptForPreview(devices: [device], device: device, still: Self.drawnScreen(screen),
                                activeScreenID: open ? 3 : 1, angle: open ? 90 : 0)
        return session
    }

    private static func drawnScreen(_ size: CGSize) -> CGImage? {
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
