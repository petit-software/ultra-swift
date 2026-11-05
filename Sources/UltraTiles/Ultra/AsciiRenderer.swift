//  Draws an `AsciiRunner`'s grid with Core Text.
//
//  Ported from petit-software/asciisaver (`Sources/GridRenderer.swift`). Apache License,
//  Version 2.0; see `NOTICE` beside this file.
//
//  Every cell changes every frame, so drawing cell by cell is not an option: the grid is
//  flattened into one glyph array per weight and handed to `CTFontDrawGlyphs` in a single
//  call each. SIN SIN uses two weights, so a frame is two draws.

import AppKit
import CoreText

/// One cell's size, from the font.
struct AsciiMetrics: Equatable {
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat
    /// From the top of a row down to its baseline.
    let baselineOffset: CGFloat
}

@MainActor
final class AsciiRenderer {
    /// The playground's cell: LL Simple Console's 0.528em advance under `line-height: 1.2`.
    /// Rows are stretched to it so a program keeps its proportions under any font.
    static let cellAspect: CGFloat = 0.528 / 1.2

    private struct Batch {
        var weight: NSFont.Weight
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
    }

    private var batches: [Batch] = []
    private var fonts: [CGFloat: CTFont] = [:]
    private var glyphs: [CGFloat: [UInt16: CGGlyph]] = [:]
    private var fontSize: CGFloat = 0

    func metrics(forFontSize size: CGFloat) -> AsciiMetrics {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        var glyph = CGGlyph()
        var character: UniChar = 0x58 // "X"
        let advance = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            ? CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
            : size * 0.6
        let lineHeight = advance / Self.cellAspect
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        // CSS half-leading: the slack split above and below the text.
        return AsciiMetrics(cellWidth: advance, lineHeight: lineHeight, fontSize: size,
                            baselineOffset: (lineHeight - (ascent + descent)) / 2 + ascent)
    }

    /// Draw the grid into `ctx`, row 0 at the top of an unflipped view `height` tall. No
    /// background: the pane's own surface shows through the gaps, as it does a terminal's.
    func render(_ runner: AsciiRunner, metrics: AsciiMetrics, colour: CGColor,
                defaultWeight: NSFont.Weight, height: CGFloat, in ctx: CGContext) {
        if fontSize != metrics.fontSize {
            fontSize = metrics.fontSize
            fonts.removeAll()
            glyphs.removeAll()
        }
        guard runner.cols > 0, runner.rows > 0 else { return }
        for i in batches.indices {
            batches[i].glyphs.removeAll(keepingCapacity: true)
            batches[i].positions.removeAll(keepingCapacity: true)
        }
        let cells = runner.cells
        for y in 0..<runner.rows {
            let baseline = height - (CGFloat(y) * metrics.lineHeight + metrics.baselineOffset)
            let row = y * runner.cols
            for x in 0..<runner.cols {
                let cell = cells[row + x]
                let scalar = cell.char.value
                // A space has no ink.
                if scalar == 0x20 || scalar == 0 { continue }
                let weight = cell.weight ?? defaultWeight
                guard let glyph = glyph(for: scalar, weight: weight) else { continue }
                let index = batchIndex(weight)
                batches[index].glyphs.append(glyph)
                batches[index].positions.append(CGPoint(x: CGFloat(x) * metrics.cellWidth, y: baseline))
            }
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.setFillColor(colour)
        for batch in batches where !batch.glyphs.isEmpty {
            CTFontDrawGlyphs(font(weight: batch.weight), batch.glyphs, batch.positions,
                             batch.glyphs.count, ctx)
        }
        ctx.restoreGState()
    }

    private func batchIndex(_ weight: NSFont.Weight) -> Int {
        if let index = batches.firstIndex(where: { $0.weight == weight }) { return index }
        batches.append(Batch(weight: weight))
        return batches.count - 1
    }

    private func font(weight: NSFont.Weight) -> CTFont {
        if let cached = fonts[weight.rawValue] { return cached }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight) as CTFont
        fonts[weight.rawValue] = font
        return font
    }

    private func glyph(for scalar: UInt32, weight: NSFont.Weight) -> CGGlyph? {
        // Everything SIN SIN draws is ASCII.
        guard scalar <= 0xFFFF else { return nil }
        let unit = UInt16(scalar)
        if let cached = glyphs[weight.rawValue]?[unit] { return cached == 0 ? nil : cached }
        var character = unit
        var glyph = CGGlyph()
        let resolved = CTFontGetGlyphsForCharacters(font(weight: weight), &character, &glyph, 1) ? glyph : 0
        glyphs[weight.rawValue, default: [:]][unit] = resolved
        return resolved == 0 ? nil : resolved
    }
}
