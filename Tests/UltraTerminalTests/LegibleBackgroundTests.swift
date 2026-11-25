import Testing
import AppKit
import Foundation
import SwiftTerm
@testable import UltraTerminal
@testable import UltraDesign

/// The text typed into an agent's composer has to be readable in it, whatever theme the
/// agent thinks the pane has.
@Suite("Legible backgrounds")
@MainActor
struct LegibleBackgroundTests {
    typealias RGB = LegibleBackgrounds.RGB

    private let light = LegibleBackgrounds(theme: .light)
    private let dark = LegibleBackgrounds(theme: .dark)

    // MARK: The rule

    @Test("Claude Code's brightBlack message block is washed on the light theme, kept on the dark")
    func brightBlackSurface() throws {
        let onLight = try #require(light.washed(light.color(ansi: 8)))
        #expect(light.foreground.contrast(with: onLight) >= 7)
        #expect(onLight.luminance < light.background.luminance, "still a surface, not the pane")
        #expect(dark.washed(dark.color(ansi: 8)) == nil)
    }

    @Test("a composer mixed for the dark pane is washed once the pane is light, and the reverse")
    func staleComposer() throws {
        // What Codex draws: the background it read at launch, 12% towards white on a dark
        // pane and 4% towards black on a light one.
        let forDark = dark.background.mixed(with: RGB(r: 1, g: 1, b: 1), by: 0.12)
        let forLight = light.background.mixed(with: RGB(r: 0, g: 0, b: 0), by: 0.04)
        #expect(dark.washed(forDark) == nil)
        #expect(light.washed(forLight) == nil)

        let onLight = try #require(light.washed(forDark))
        #expect(light.foreground.contrast(with: onLight) >= 7)
        let onDark = try #require(dark.washed(forLight))
        #expect(dark.foreground.contrast(with: onDark) >= 7)
    }

    @Test("a colour is left as the program sent it, readable or not")
    func coloursAreKept() {
        for code: UInt8 in [1, 2, 3, 4, 5, 6, 9, 12, 21, 196] {
            #expect(light.washed(light.color(ansi: code)) == nil)
            #expect(dark.washed(dark.color(ansi: code)) == nil)
        }
    }

    @Test("a cell with its own colour goes with the surface only when it loses nothing")
    func explicitForeground() {
        let surface = light.color(ansi: 8)
        // A dim grey prompt mark reads better on the wash; a white label does not.
        #expect(light.washed(surface, under: RGB(r: 0.45, g: 0.47, b: 0.5)) != nil)
        #expect(light.washed(surface, under: RGB(r: 1, g: 1, b: 1)) == nil)
    }

    // MARK: In a pane

    private func cell(_ shell: ShellTerminalView, column: Int = 0) -> Attribute {
        shell.getTerminal().getLine(row: 0)![column].attribute
    }

    private func rgb(_ color: Attribute.Color) -> RGB? {
        if case .trueColor(let r, let g, let b) = color { return RGB(r8: r, g8: g, b8: b) }
        return nil
    }

    private func feed(_ shell: ShellTerminalView, _ text: String) {
        shell.dataReceived(slice: Array(text.utf8)[...])
    }

    @Test("text on brightBlack in a light pane is drawn on a tint, with its style intact")
    func washedAsItArrives() throws {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .light))
        feed(shell, "\u{1b}[H\u{1b}[100m\u{1b}[2m> \u{1b}[22mi want light mode\u{1b}[0m plain")

        let mark = cell(shell)
        let surface = try #require(rgb(mark.bg))
        #expect(light.foreground.contrast(with: surface) >= 7)
        #expect(mark.style.contains(.dim), "the wash changes the background and nothing else")
        #expect(mark.fg == .defaultColor)
        #expect(cell(shell, column: 5).bg == mark.bg)
        #expect(cell(shell, column: 22).bg == .defaultColor)
    }

    @Test("the same bytes in a dark pane are left alone")
    func keptWhereReadable() {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .dark))
        feed(shell, "\u{1b}[H\u{1b}[100mhello\u{1b}[0m")
        #expect(cell(shell).bg == .ansi256(code: 8))
    }

    @Test("a composer drawn for the dark pane turns light with the pane, and follows it back")
    func followsTheTheme() throws {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .dark))
        let (r, g, b) = dark.background.mixed(with: RGB(r: 1, g: 1, b: 1), by: 0.12).bytes
        let composer = "\u{1b}[H\u{1b}[48;2;\(r);\(g);\(b)m> hello\u{1b}[0m"
        feed(shell, composer)
        #expect(cell(shell).bg == .trueColor(red: r, green: g, blue: b))

        shell.apply(theme: .light)
        let onLight = try #require(rgb(cell(shell).bg))
        #expect(light.foreground.contrast(with: onLight) >= 7)

        // The agent still thinks the pane is dark, and redraws its composer as before.
        feed(shell, composer)
        #expect(rgb(cell(shell).bg) == onLight)

        shell.apply(theme: .dark)
        let backOnDark = try #require(rgb(cell(shell).bg))
        #expect(dark.foreground.contrast(with: backOnDark) >= 7)
    }

    @Test("a red background and a reverse-video cell are not touched")
    func leavesTheRestAlone() {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .light))
        feed(shell, "\u{1b}[H\u{1b}[41mE\u{1b}[0m\u{1b}[100;7mR\u{1b}[0m\u{1b}[100;38;2;255;255;255mW\u{1b}[0m")
        #expect(cell(shell, column: 0).bg == .ansi256(code: 1))
        #expect(cell(shell, column: 1).bg == .ansi256(code: 8))
        #expect(cell(shell, column: 2).bg == .ansi256(code: 8), "white on grey was chosen as a pair")
    }

    @Test("a line that scrolled away before the pane could look at it is washed too")
    func scrolledAway() throws {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .light))
        let terminal = shell.getTerminal()
        feed(shell, "\u{1b}[100mfirst\u{1b}[0m" + String(repeating: "\r\n", count: terminal.rows + 5))
        let first = try #require(terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed))
        #expect(rgb(first[0].attribute.bg) != nil)
    }
}
