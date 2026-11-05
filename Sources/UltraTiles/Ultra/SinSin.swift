//  "Sin Sin" by ertdfgcvb — https://play.ertdfgcvb.xyz/#/src/demos/sinsin_checker
//
//  Ported from petit-software/asciisaver (`Sources/Programs/SinSinChecker.swift`), a port
//  of play.core's `src/programs/demos/sinsin_checker.js`. Apache License, Version 2.0;
//  see `NOTICE` beside this file. The original, verbatim:
//
//      const pattern = [
//          ' _000111_ ',
//          '.+abc+.      '
//      ]
//      const weights = [100, 700]
//      const { floor, sin } = Math
//
//      export function main(coord, context, cursor, buffer) {
//          const t = context.time * 0.001
//          const x = coord.x - context.cols / 2
//          const y = coord.y - context.rows / 2
//          const o = sin(x * y * 0.0017 + y * 0.0033 + t ) * 40
//          const i = floor(Math.abs(x + y + o))
//          const c = (floor(coord.x * 0.09) + floor(coord.y * 0.09)) % 2
//          return {
//              char : pattern[c][i % pattern[c].length],
//              color : 'black',
//              fontWeight : weights[c],
//          }
//      }

import AppKit

struct SinSin: AsciiProgram {
    private let patterns = [
        Array(" _000111_ ".unicodeScalars),
        Array(".+abc+.      ".unicodeScalars),
    ]

    /// CSS `font-weight` 100 and 700.
    private let weights: [NSFont.Weight] = [.ultraLight, .bold]

    func main(_ coord: AsciiCoord, _ context: AsciiContext, _ cell: inout AsciiCell) {
        let t = context.time * 0.001
        // JS division: an odd grid puts the origin between two cells.
        let x = Double(coord.x) - Double(context.cols) / 2
        let y = Double(coord.y) - Double(context.rows) / 2
        let o = sin(x * y * 0.0017 + y * 0.0033 + t) * 40
        let i = Int(abs(x + y + o).rounded(.down))
        let c = (Int((Double(coord.x) * 0.09).rounded(.down))
                 + Int((Double(coord.y) * 0.09).rounded(.down))) % 2
        let pattern = patterns[c]
        cell.char = pattern[i % pattern.count]
        cell.weight = weights[c]
    }
}
