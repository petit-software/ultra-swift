import AppKit
import Foundation
import UltraSimulator

/// One simulator pane's device: which one, whether it is up, its live screen, and the
/// verbs the pane's chrome and the agent channel share.
///
/// Owned by `TileFactory`, not by the view, for the reason a browser's page is: a pane is
/// rebuilt whenever it is restored, converted or retargeted, and the display connection
/// living in the view would be torn down and re-made — a black flash and a lost touch —
/// every time the layout so much as hiccuped.
///
/// Two paths to the device, on purpose. Listing, booting, appearance and URLs go through
/// `xcrun simctl`, which is Apple's supported surface. The screen and touches go through
/// Xcode's private frameworks (`SimulatorFrameworks`), because nothing else can do them.
/// When the private path is not available the pane still works with a screenshot that
/// refreshes, and says why it is not live.
@MainActor
@Observable
public final class SimulatorSession {

    /// Every device on this machine, booted first. Refreshed while the pane is showing.
    public private(set) var devices: [SimulatorDevice] = []
    /// The device this pane is on, or nil for a pane that has not chosen one.
    public private(set) var device: SimulatorDevice?
    /// Booting or shutting down at the pane's request: the footer shows a spinner and dims
    /// the verbs that would collide.
    public private(set) var isBusy = false
    /// The device's appearance as `simctl` reports it. Nil until asked.
    public private(set) var appearance: SimulatorControl.Appearance?
    /// Why the last thing failed, in words, for the notice bar. Cleared by the next verb.
    public var error: String?
    /// Why the screen is not live — the private path is unavailable — so the pane can say
    /// it once, quietly, under the still picture.
    public private(set) var liveError: String?
    /// Whether frames are arriving from the device's own framebuffer.
    public private(set) var isLive = false
    /// A still of the screen for a pane that is not live: a screenshot, refreshed on a slow
    /// poll, or nothing for a device that is shut down.
    public private(set) var still: CGImage?
    /// Bumped to ask the pane to give the keyboard to the screen — a Simulator command
    /// arrived from the menu bar and the next keys should reach the device.
    public private(set) var focusRequest = 0

    /// The device changed: the pane's header and its saved record follow.
    @ObservationIgnored public var onChange: ((SimulatorDevice?) -> Void)?
    /// Where a screenshot goes and what to do with it — the project's `.ultra/` folder, and
    /// the shell's prompt. Set by the tile factory from the tile context.
    @ObservationIgnored public var screenshotFolder: URL?
    @ObservationIgnored public var sendToShell: ((String) -> Void)?

    @ObservationIgnored private var madeView: SimulatorDisplayView?
    @ObservationIgnored private var display: SimulatorDisplay?
    @ObservationIgnored private var input: SimulatorInput?
    @ObservationIgnored private var connectedUDID: String?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var pendingApp: String?

    /// How large the device is drawn, as a multiple of the size that fits the pane. 1 fits.
    /// Saved with the pane, so a restored workspace shows the device the same size.
    public private(set) var zoom: CGFloat = 1

    /// The zoom changed: the pane's saved record follows.
    @ObservationIgnored public var onZoomChange: ((CGFloat) -> Void)?

    public init(udid: String? = nil, zoom: CGFloat = 1) {
        self.zoom = SimulatorDisplayView.clampZoom(zoom)
        if let udid {
            // A restored pane knows its device before the list is in: a placeholder with
            // the id, replaced by the real entry on the first refresh.
            device = SimulatorDevice(udid: udid, name: "Simulator", runtime: "", state: .unknown)
        }
    }

    /// The device's UDID, what the pane's record persists.
    public var udid: String? { device?.udid }
    public var isBooted: Bool { device?.state.isBooted ?? false }
    public var hasXcode: Bool { SimulatorControl.hasXcode }

    // MARK: - The view

    /// The screen, made the first time it is asked for. The session, not the view, owns it,
    /// so a rebuilt pane gets the same layer back rather than a black one.
    public var displayView: SimulatorDisplayView {
        if let madeView { return madeView }
        let view = SimulatorDisplayView(frame: .zero)
        view.zoom = zoom
        // A pinch on the screen: kept here, so the menu, the footer and the record follow.
        view.onZoom = { [weak self] in self?.setZoom($0) }
        madeView = view
        applyContents()
        return view
    }

    public var existingDisplayView: SimulatorDisplayView? { madeView }

    // MARK: - Lifecycle

    /// Start watching devices. Called when the pane appears; the poll runs until `stop`.
    public func start() {
        guard poll == nil, device?.udid.hasPrefix("PREVIEW") != true else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                await TilePolling.tick(2)
            }
        }
    }

    public func stop() {
        poll?.cancel()
        poll = nil
    }

    /// Let go of the device: the display callbacks, the touch client, the poll.
    public func close() {
        stop()
        disconnect()
    }

    /// One poll: the device list, the chosen device's state, and the connection to its
    /// screen when it is up.
    private func tick() async {
        guard SimulatorControl.hasXcode else {
            liveError = "Xcode is not installed, so there are no simulators"
            return
        }
        do {
            let list = try await SimulatorControl.listDevices()
            devices = list
            if let current = device, let fresh = list.first(where: { $0.udid == current.udid }) {
                if fresh != current {
                    device = fresh
                    onChange?(fresh)
                    // A restored pane learns its device type here, and so its enclosure.
                    if fresh.deviceType != current.deviceType { applyContents() }
                }
            } else if let current = device, current.state == .unknown, !list.isEmpty {
                // A restored device that no longer exists: say so rather than sit on a name.
                error = "The simulator this pane was on has been deleted"
                device = nil
                onChange?(nil)
            }
        } catch {
            self.error = "\(error)"
        }
        await syncConnection()
    }

    /// Connect to a booted device's screen, or let go of one that went down.
    private func syncConnection() async {
        guard let device, device.state.isBooted else {
            disconnect()
            still = nil
            applyContents()
            return
        }
        if connectedUDID == device.udid, let display {
            // Connected, but not showing the live screen — the device had no framebuffer
            // yet when it connected, say. Look again rather than wait on a callback.
            if madeView?.contents == nil || madeView?.input == nil { display.refresh() }
            return
        }
        disconnect()
        connectedUDID = device.udid
        let frameworks = SimulatorFrameworks.shared
        if frameworks.isAvailable {
            do {
                let handle = try frameworks.device(udid: device.udid)
                if let found = SimulatorDisplay.find(for: handle) {
                    display = found
                    found.onFrame = { [weak self] in self?.frameArrived() }
                    found.start()
                    isLive = true
                    // The screen is live from here: a screenshot taken while it was not is
                    // stale, and must not be shown in its place while the first frame comes.
                    still = nil
                    liveError = nil
                    do {
                        input = try SimulatorInput(device: handle)
                    } catch {
                        liveError = "\(error)"
                    }
                } else {
                    liveError = "The device has no display yet — it may still be starting"
                    isLive = false
                }
            } catch {
                liveError = "\(error)"
                isLive = false
            }
        } else {
            liveError = frameworks.error.map { "\($0)" } ?? "The live screen is not available"
            isLive = false
        }
        if !isLive { await refreshStill() }
        applyContents()
        if let app = pendingApp {
            pendingApp = nil
            await launch(app)
        }
    }

    private func disconnect() {
        display?.stop()
        display = nil
        input = nil
        connectedUDID = nil
        isLive = false
    }

    private func frameArrived() {
        madeView?.frameDidChange()
        guard let display, let view = madeView else { return }
        // Re-point the view whenever it is not showing the live surface — not only when the
        // size or the angle moved. A device just booted connects before it has a
        // framebuffer, so the pane first shows the screenshot of its boot screen, with
        // input off; that screenshot is exactly the framebuffer's size, and a size check
        // alone left the pane on it for good: frozen, and deaf to every click.
        let surface = display.maskedSurface ?? display.surface
        if view.contents !== surface || view.angle != display.angle || view.pixelSize != display.pixelSize {
            applyContents()
        }
    }

    /// Point the view at whatever there is to show: the framebuffer, a still, or nothing.
    private func applyContents() {
        guard let view = madeView else { return }
        if let display, let surface = display.maskedSurface ?? display.surface {
            view.contents = surface
            view.pixelSize = display.pixelSize
            view.angle = display.angle
            view.input = input
            view.chrome = chrome
            view.cornerMask = cornerMask
        } else if let still {
            view.contents = still
            view.pixelSize = CGSize(width: still.width, height: still.height)
            view.angle = 0
            view.input = nil
            view.chrome = chrome
            view.cornerMask = cornerMask
        } else {
            view.contents = nil
            view.pixelSize = .zero
            view.input = nil
            view.chrome = nil
            view.cornerMask = nil
        }
        view.frameDidChange()
    }

    /// Whether the device's enclosure is drawn round its screen. Off while the enclosure
    /// renders wrongly: the pane shows the bare screen, clipped to the device's own rounded
    /// corners (`cornerMask`). `DeviceChrome` and its tests stay, ready to turn back on.
    static let showsEnclosure = false

    /// The device's screen corners, from the same Xcode artwork: every device its own radius.
    private var cornerMask: CGImage? {
        device.flatMap { DeviceChrome.cornerMask(deviceType: $0.deviceType) }
    }

    /// The device's enclosure, from Xcode's own artwork for its type.
    private var chrome: DeviceChrome? {
        guard Self.showsEnclosure else { return nil }
        return device.flatMap { DeviceChrome.load(deviceType: $0.deviceType) }
    }

    /// A screenshot through `simctl`, for a pane that cannot be live.
    private func refreshStill() async {
        guard let device, device.state.isBooted else { still = nil; return }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-sim-\(device.udid).png")
        guard (try? await SimulatorControl.screenshot(device.udid, to: file)) != nil,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        still = image
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: - Verbs

    /// Put the pane on a device. A shut-down device is shown as such, with Boot in the footer.
    public func choose(_ chosen: SimulatorDevice) {
        error = nil
        guard chosen.udid != device?.udid else { return }
        device = chosen
        onChange?(chosen)
        Task { await syncConnection() }
    }

    /// The agent's verb: this device, booted if it is not, with an app launched once it is.
    ///
    /// Returns why the app did not launch when the device was already up — the agent is
    /// waiting on the reply and can act on "not installed". A device that has to boot
    /// first launches the app when it is up, and a failure then lands in the notice bar.
    @discardableResult
    public func show(_ chosen: SimulatorDevice, launching app: String?) async -> String? {
        choose(chosen)
        guard chosen.state.isBooted else {
            pendingApp = app
            boot()
            return nil
        }
        pendingApp = nil
        guard let app else { return nil }
        return await launch(app)
    }

    public func boot() {
        guard let device, !isBusy else { return }
        error = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await SimulatorControl.boot(device.udid)
                await tick()
            } catch {
                self.error = "\(error)"
            }
        }
    }

    public func shutdown() {
        guard let device, !isBusy else { return }
        error = nil
        isBusy = true
        disconnect()
        Task {
            defer { isBusy = false }
            do {
                try await SimulatorControl.shutdown(device.udid)
                await tick()
            } catch {
                self.error = "\(error)"
            }
        }
    }

    public func pressHome() { input?.press(.home) }
    public func pressLock() { input?.press(.lock) }
    public var canPress: Bool { input != nil }

    /// Launch an app by bundle id. Returns, and shows, why not.
    @discardableResult
    public func launch(_ app: String) async -> String? {
        guard let device else { return "no device" }
        do {
            try await SimulatorControl.launch(app, on: device.udid)
            return nil
        } catch {
            self.error = "\(error)"
            return "\(error)"
        }
    }

    public func open(_ url: URL) {
        guard let device else { return }
        error = nil
        Task {
            do { try await SimulatorControl.openURL(url, on: device.udid) } catch { self.error = "\(error)" }
        }
    }

    public func toggleAppearance() {
        guard let device else { return }
        error = nil
        Task {
            var current = appearance
            if current == nil { current = await SimulatorControl.appearance(of: device.udid) }
            let next: SimulatorControl.Appearance = current == .dark ? .light : .dark
            do {
                try await SimulatorControl.setAppearance(next, on: device.udid)
                appearance = next
            } catch {
                self.error = "\(error)"
            }
        }
    }

    /// The screen as a PNG in the project's `.ultra/screenshots/`, and its path typed at
    /// the shell's prompt: the fastest way to put what is on screen in front of the agent.
    @discardableResult
    public func takeScreenshot() async -> URL? {
        guard let device else { return nil }
        error = nil
        let folder = (screenshotFolder ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: Date())
        let name = device.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
        let file = folder.appendingPathComponent("\(name)-\(stamp).png")
        // `simctl` first: read on the CPU straight after a change, the live framebuffer now
        // and then still holds the screen before it, and a screenshot of what WAS on screen
        // is worse than one that takes half a second. The framebuffer is the fallback.
        do {
            try await SimulatorControl.screenshot(device.udid, to: file)
        } catch {
            guard let image = display?.snapshot(),
                  let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
                self.error = "\(error)"; return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { self.error = "Could not write the screenshot"; return nil }
        }
        sendToShell?(file.path)
        return file
    }

    public func focusScreen() { focusRequest += 1 }

    // MARK: - Zoom

    public var canZoomIn: Bool { zoom < SimulatorDisplayView.zoomRange.upperBound - 0.001 }
    public var canZoomOut: Bool { zoom > SimulatorDisplayView.zoomRange.lowerBound + 0.001 }
    public var isFitted: Bool { abs(zoom - 1) < 0.001 }

    public func zoomIn() { setZoom(SimulatorDisplayView.zoomStep(from: zoom, in: true)) }
    public func zoomOut() { setZoom(SimulatorDisplayView.zoomStep(from: zoom, in: false)) }
    public func zoomToFit() { setZoom(1) }

    /// The zoom as the footer says it: "Fit", or a percentage of the fitted size.
    public var zoomLabel: String { isFitted ? "Fit" : "\(Int((zoom * 100).rounded()))%" }

    private func setZoom(_ value: CGFloat) {
        // Two places, so a pinch does not write the record at every intermediate step.
        let next = (SimulatorDisplayView.clampZoom(value) * 100).rounded() / 100
        guard next != zoom else { return }
        zoom = next
        madeView?.zoom = next
        onZoomChange?(next)
    }

    /// A preview's fixture: devices and a still, with no Xcode asked and no poll started.
    func adoptForPreview(devices: [SimulatorDevice], device: SimulatorDevice?, still: CGImage?) {
        self.devices = devices
        self.device = device
        self.still = still
        liveError = still == nil ? nil : "preview"
        applyContents()
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

import ImageIO
