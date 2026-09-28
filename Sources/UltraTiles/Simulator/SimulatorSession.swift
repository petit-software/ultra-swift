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

    public init(udid: String? = nil) {
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
        if connectedUDID == device.udid, display != nil { return }
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
        if let display, madeView?.angle != display.angle || madeView?.pixelSize != display.pixelSize {
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
        } else if let still {
            view.contents = still
            view.pixelSize = CGSize(width: still.width, height: still.height)
            view.angle = 0
            view.input = nil
            view.chrome = chrome
        } else {
            view.contents = nil
            view.pixelSize = .zero
            view.input = nil
            view.chrome = nil
        }
        view.frameDidChange()
    }

    /// The device's enclosure, from Xcode's own artwork for its type.
    private var chrome: DeviceChrome? {
        device.flatMap { DeviceChrome.load(deviceType: $0.deviceType) }
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
    public func show(_ chosen: SimulatorDevice, launching app: String?) {
        choose(chosen)
        pendingApp = app
        if chosen.state.isBooted {
            if let app { pendingApp = nil; Task { await launch(app) } }
        } else {
            boot()
        }
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

    public func launch(_ app: String) async {
        guard let device else { return }
        do { try await SimulatorControl.launch(app, on: device.udid) } catch { self.error = "\(error)" }
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
        if let image = display?.snapshot() {
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
                error = "Could not write the screenshot"; return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { error = "Could not write the screenshot"; return nil }
        } else {
            do { try await SimulatorControl.screenshot(device.udid, to: file) } catch { self.error = "\(error)"; return nil }
        }
        sendToShell?(file.path)
        return file
    }

    public func focusScreen() { focusRequest += 1 }

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
