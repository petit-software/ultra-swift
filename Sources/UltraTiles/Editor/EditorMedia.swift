import Foundation
import UniformTypeIdentifiers

/// A file the editor shows rather than edits: a picture, a film, a sound, a PDF.
///
/// Told by the file's TYPE, from its extension — the way Finder and Quick Look tell — and
/// not by its bytes: a film is not read into memory to find out it is not text. A file
/// whose name says nothing falls through to the editor's own test, a NUL byte, and is
/// "Not a text file" as before.
///
/// Anything that is also text stays text. An SVG is an image to the type system and an
/// XML file to everyone who opens it in an editor, and the editor is for editing.
public enum EditorMedia: Equatable, Sendable {
    case image
    case movie
    case audio
    case pdf

    /// What the file at `url` is, or nil when it is text, or not something to show.
    public static func kind(of url: URL) -> EditorMedia? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              !type.conforms(to: .text) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) { return .movie }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// The tab's icon, so a row of tabs says which are pictures before any is opened.
    public var symbol: String {
        switch self {
        case .image: "photo"
        case .movie: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        }
    }
}
