import AVKit
import AppKit
import PDFKit
import SwiftUI
import UltraDesign
import UniformTypeIdentifiers

/// A file the editor shows rather than edits — see `EditorMedia`.
///
/// Each kind in the system's own view for it: a picture as itself, a PDF in PDFKit's
/// view, a film or a sound in AVKit's player. None of them is reimplemented here, and
/// none of them is a step towards editing; changing a picture is another app's job.
///
/// `revision` is the document's count of changes on disk. Each view loads its file again
/// when it moves, so a screenshot taken over the last one shows the new one.
struct MediaView: View {
    let url: URL
    let kind: EditorMedia
    let revision: Int

    var body: some View {
        switch kind {
        case .image:
            ImageMediaView(url: url, revision: revision)
        case .pdf:
            PDFMediaView(url: url, revision: revision)
        case .movie:
            PlayerMediaView(url: url, revision: revision)
        case .audio:
            AudioMediaView(url: url, revision: revision)
        }
    }
}

// MARK: - Images

/// A picture at its own size, or smaller to fit the pane — never larger, so an icon is
/// an icon and not a blur. Over a checkerboard, so a transparent PNG shows where it is
/// transparent rather than taking on the pane's colour; under it, what the picture is:
/// its size in pixels, its type, and its size on disk.
private struct ImageMediaView: View {
    let url: URL
    let revision: Int
    @State private var loaded: LoadedImage?
    @State private var failed = false

    var body: some View {
        // A ZStack over a clear fill, not a Group: until the picture has loaded there is
        // nothing else in here, and modifiers on a view with nothing in it are dropped —
        // the task that loads the picture with them, so it never loaded at all.
        ZStack {
            Color.clear
            if let loaded {
                VStack(spacing: 8) {
                    Image(nsImage: loaded.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        // Behind the fitted picture only, not the frame around it.
                        .background(Checkerboard())
                        .frame(maxWidth: loaded.image.size.width,
                               maxHeight: loaded.image.size.height)
                        .accessibilityLabel(url.lastPathComponent)
                    Text(loaded.caption)
                        .font(Token.Type_.monoSmall)
                        .foregroundStyle(Token.Colour.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(Token.Space.tileBodyInset * 2)
            } else if failed {
                EmptyTileState(icon: EditorMedia.image.symbol, title: "This image could not be shown")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: revision) { await load() }
    }

    /// The bytes off the main actor — a camera's photo is tens of megabytes — and the
    /// image made from them on it, since an `NSImage` is not something to hand across.
    private func load() async {
        let url = url
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        guard let data, let image = NSImage(data: data), image.size.width > 0 else {
            loaded = nil
            failed = true
            return
        }
        failed = false
        loaded = LoadedImage(image: image, caption: Self.caption(image, url: url, bytes: data.count))
    }

    /// "1170 × 2532 · PNG image · 412 KB". Pixels, not points: a Retina screenshot is
    /// twice the size it is drawn at, and the pixels are what someone asking is after.
    static func caption(_ image: NSImage, url: URL, bytes: Int) -> String {
        var parts: [String] = []
        let widest = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let rep = widest, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
        }
        if let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            parts.append(type)
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

private struct LoadedImage {
    let image: NSImage
    let caption: String
}

/// The squares behind a picture with transparent parts. Quiet — the label colour at a
/// few percent — so it reads as "nothing here" in either appearance and never competes
/// with the picture on top of it.
private struct Checkerboard: View {
    static let cell: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let columns = Int((size.width / Self.cell).rounded(.up))
            let rows = Int((size.height / Self.cell).rounded(.up))
            var squares = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * Self.cell,
                                           y: CGFloat(row) * Self.cell,
                                           width: Self.cell, height: Self.cell))
                }
            }
            context.fill(squares, with: .color(Token.Colour.label.opacity(0.07)))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - PDF

/// PDFKit's view, scaled to the pane's width and scrolling through the pages — what
/// Preview does with a document, without the sidebar.
private struct PDFMediaView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        // The pane's own surface around the pages, not PDFKit's grey.
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.document = PDFDocument(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}

// MARK: - Films and sounds

/// AVKit's player with its controls in the frame. Space plays and pauses once the player
/// has the keyboard, which a click in the pane gives it.
///
/// Stopped when its view goes — another tab chosen, the pane closed — rather than left
/// playing somewhere nothing shows it.
private struct PlayerMediaView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        view.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var revision = 0
    }
}

/// A sound: its name, and one row of controls — play, where it is, how long it is.
///
/// Drawn here rather than in AVKit's player. With no picture to frame, AVKit's inline
/// controls sat in a grey box the size of a video, with a second set of floating controls
/// over the first. A sound wants three things, and they are three things the app already
/// knows how to draw.
///
/// Play is a button, so Tab reaches it with Full Keyboard Access and Space presses it.
/// Stopped when the view goes — another tab chosen, the pane closed.
private struct AudioMediaView: View {
    let url: URL
    let revision: Int
    @State private var playback = AudioPlayback()

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: EditorMedia.audio.symbol)
                .font(.system(size: 34))
                .foregroundStyle(Token.Colour.tertiaryLabel)
                .symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
            Text(url.lastPathComponent)
                .font(Token.Type_.tileSubtitle)
                .foregroundStyle(Token.Colour.secondaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Token.Colour.label)
                .help(playback.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Text(Self.time(playback.elapsed))
                    .frame(minWidth: 34, alignment: .trailing)
                Slider(value: Binding(get: { playback.elapsed }, set: { playback.seek(to: $0) }),
                       in: 0...max(playback.duration, 0.01))
                    .controlSize(.small)
                    .disabled(playback.duration == 0)
                    .accessibilityLabel("Position")
                Text(Self.time(playback.duration))
                    .frame(minWidth: 34, alignment: .leading)
            }
            .font(Token.Type_.monoSmall)
            .foregroundStyle(Token.Colour.tertiaryLabel)
            .frame(maxWidth: 420)
        }
        .padding(Token.Space.tileBodyInset * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: revision) { playback.load(url) }
        .onDisappear { playback.stop() }
    }

    /// "0:02", "12:40", "1:02:03".
    static func time(_ seconds: Double) -> String {
        let whole = Int(seconds.isFinite ? max(0, seconds) : 0)
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

/// One sound, playing or not, and where it is.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        elapsed = 0
        duration = 0
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    self.elapsed = time.seconds
                }
            }
        // Back to the start at the end, ready to play again, as a player in Finder does.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaying = false
                    self.seek(to: 0)
                }
            }
        let asset = item.asset
        Task { [weak self] in
            guard let length = try? await asset.load(.duration), length.seconds.isFinite else { return }
            self?.duration = length.seconds
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
    }
}

#Preview("Image", traits: .fixedLayout(width: 420, height: 360)) {
    MediaView(url: MediaPreviewFixture.image, kind: .image, revision: 0)
}

#Preview("Sound", traits: .fixedLayout(width: 420, height: 260)) {
    MediaView(url: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), kind: .audio, revision: 0)
}

/// A picture with a transparent corner, written once for the previews.
enum MediaPreviewFixture {
    @MainActor static let image: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ultra-preview.png")
        let size = NSSize(width: 240, height: 160)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 24, yRadius: 24).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        return url
    }()
}
