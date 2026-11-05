import AppKit
import SwiftUI
import UltraDesign

/// The Ultra pane: asciisaver's SIN SIN, playing in the pane at the terminal's font size.
///
/// Something to look at while an agent works, and the right-hand column a new user's
/// first project opens with (`ShellWorkspace.starterDocument`).
///
/// Driven by the view's own display link, which the system pauses when the view is off
/// screen; a frame is also skipped while every window is occluded, the rule the polling
/// tiles follow (`TilePolling`). Thirty frames a second, play.core's default — the
/// animation is slow enough that more would only cost power. With Reduce Motion on it
/// draws one still frame.
@MainActor
public final class UltraPaneView: NSView {
    private let runner = AsciiRunner(program: SinSin())
    private let renderer = AsciiRenderer()
    private var metrics: AsciiMetrics?
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var observers = ObserverBox()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Ultra")
        setAccessibilityHelp("An ASCII animation: Sin Sin, by ertdfgcvb")
        // A new font size is a new grid, picked up on the next frame.
        observers.add(NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.metrics = nil; self?.needsDisplay = true }
            })
        observers.add(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLink() }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { false }
    public override var isOpaque: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let animates = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animates, link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
            lastFrame = 0
        } else if !animates, let link {
            link.invalidate()
            self.link = nil
        }
        needsDisplay = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window, window.occlusionState.contains(.visible) else {
            // Hidden: the clock stops with the pixels rather than leaping ahead on return.
            lastFrame = 0
            return
        }
        let now = link.timestamp
        // Clamped, so a stall does not jump the animation.
        let delta = lastFrame == 0 ? 1.0 / 30 : min(now - lastFrame, 0.25)
        lastFrame = now
        advance(by: delta)
        needsDisplay = true
    }

    private func currentMetrics() -> AsciiMetrics {
        let size = Preferences.terminalFontSize
        if let metrics, metrics.fontSize == size { return metrics }
        let fresh = renderer.metrics(forFontSize: size)
        metrics = fresh
        return fresh
    }

    private func grid(_ metrics: AsciiMetrics) -> (cols: Int, rows: Int) {
        // One cell over, so the pattern runs to the pane's edges rather than stopping short.
        (Int(ceil(bounds.width / metrics.cellWidth)), Int(ceil(bounds.height / metrics.lineHeight)))
    }

    private func advance(by seconds: Double) {
        let size = grid(currentMetrics())
        runner.step(deltaMS: seconds * 1000, cols: size.cols, rows: size.rows)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let metrics = currentMetrics()
        let size = grid(metrics)
        // A pane laid out since the last frame — or one that never animates — is filled
        // at its new size without moving the clock.
        if size.cols != runner.cols || size.rows != runner.rows {
            runner.step(deltaMS: 0, cols: size.cols, rows: size.rows)
        }
        // Resolved here, under the view's appearance, so a pane pinned light or dark — and
        // the app switching — draws in the right ink.
        let colour = NSColor.labelColor.cgColor
        renderer.render(runner, metrics: metrics, colour: colour, defaultWeight: .ultraLight,
                        height: bounds.height, in: ctx)
    }

    /// One frame at an elapsed time, for previews and tests: the view's own clock does
    /// not run without a window.
    func showFrame(atSeconds seconds: Double) {
        advance(by: seconds)
        needsDisplay = true
    }
}

#Preview("Ultra", traits: .fixedLayout(width: 420, height: 320)) {
    let view = UltraPaneView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    view.showFrame(atSeconds: 4)
    return view
}
