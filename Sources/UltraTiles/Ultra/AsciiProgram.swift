//  The play.core runtime, as far as the Ultra pane needs it.
//
//  Ported from petit-software/asciisaver (`Sources/Runner.swift`), itself a port of
//  play.core (https://github.com/ertdfgcvb/play.core) by ertdfgcvb. Both are licensed
//  under the Apache License, Version 2.0; see `NOTICE` beside this file.
//
//  The model is play.core's: once a frame, walk a grid of character cells and ask the
//  program for the character at each one. The saver's colours, backgrounds and drawing
//  helpers are left out — SIN SIN sets a character and a weight, and nothing else.

import AppKit

/// One character cell. A nil weight is the renderer's default.
struct AsciiCell: Equatable {
    var char: UnicodeScalar = " "
    var weight: NSFont.Weight?
}

/// Where a cell is, handed to the program with it.
struct AsciiCoord {
    let x: Int
    let y: Int
}

/// Per-frame facts for the program: play.core's `context`.
struct AsciiContext {
    let frame: Int
    /// Milliseconds since the program started, as play.core's `context.time` is.
    let time: Double
    let cols: Int
    let rows: Int
}

/// A play.core program: the character at one cell, for one frame.
protocol AsciiProgram {
    func main(_ coord: AsciiCoord, _ context: AsciiContext, _ cell: inout AsciiCell)
}

/// The clock and the grid, filled one frame at a time.
///
/// Main-actor bound because the pane that owns it draws from it: the grid is a few
/// thousand cells, filled in well under a millisecond, and not worth a second thread.
@MainActor
final class AsciiRunner {
    let program: any AsciiProgram
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var cells: [AsciiCell] = []
    private(set) var frame = 0
    /// Milliseconds of animation so far. Advanced by real elapsed time, so a pane that
    /// drops frames keeps the animation's speed rather than slowing down with it.
    private(set) var time: Double = 0

    init(program: any AsciiProgram) { self.program = program }

    /// Advance the clock by `deltaMS` and repaint every cell at `cols` × `rows`.
    ///
    /// A new size starts from a clean grid: a cell keeps last frame's fields unless the
    /// program sets them — play.core's merge — and a cell from another size is not this
    /// cell's last frame.
    func step(deltaMS: Double, cols: Int, rows: Int) {
        let cols = max(0, cols), rows = max(0, rows)
        if cols != self.cols || rows != self.rows {
            self.cols = cols
            self.rows = rows
            cells = Array(repeating: AsciiCell(), count: cols * rows)
        }
        time += deltaMS
        frame += 1
        let context = AsciiContext(frame: frame, time: time, cols: cols, rows: rows)
        for y in 0..<rows {
            for x in 0..<cols {
                program.main(AsciiCoord(x: x, y: y), context, &cells[y * cols + x])
            }
        }
    }
}
