import Testing
import AppKit
import Foundation
@testable import UltraTerminal
@testable import UltraDesign

/// A program that asked to hear about a light/dark switch has to hear about it: it chose
/// its own colours from the pane's old background, and keeps them otherwise.
@Suite("Colour scheme reports")
@MainActor
struct ColorSchemeReportTests {

    private func scan(_ chunks: String...) -> [ColorSchemeReports.Request] {
        var scanner = ColorSchemeReports.Scanner()
        return chunks.flatMap { scanner.scan(Array($0.utf8)) }
    }

    @Test("subscribing, unsubscribing and asking are each recognised")
    func recognisesRequests() {
        #expect(scan("\u{1b}[?2031h") == [.notify(true)])
        #expect(scan("\u{1b}[?2031l") == [.notify(false)])
        #expect(scan("\u{1b}[?996n") == [.query])
        #expect(scan("text\u{1b}[?2031h\u{1b}[?996nmore") == [.notify(true), .query])
    }

    @Test("a mode set along with others in one sequence still counts")
    func combinedModes() {
        #expect(scan("\u{1b}[?1004;2031;2004h") == [.notify(true)])
    }

    @Test("a sequence split across reads is still one sequence")
    func splitAcrossReads() {
        #expect(scan("\u{1b}", "[?20", "31", "h") == [.notify(true)])
        #expect(scan("\u{1b}[?99", "6n") == [.query])
    }

    @Test("lookalikes are left alone")
    func lookalikes() {
        #expect(scan("\u{1b}[?2031$p").isEmpty)        // DECRQM: a different question
        #expect(scan("\u{1b}[2031h").isEmpty)          // not a private mode
        #expect(scan("\u{1b}[?12031h\u{1b}[?20310h").isEmpty)
        #expect(scan("\u{1b}[?2004h\u{1b}[?25l\u{1b}[6n\u{1b}[?6n").isEmpty)
        #expect(scan("?2031h [?2031h").isEmpty)        // no escape, just text
        #expect(scan("\u{1b}]0;\u{1b}[?2031h").count == 1)
    }

    @Test("a subscribed pane is told when its theme turns light, and when it turns back")
    func reportsOnThemeChange() {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .dark))
        var sent: [String] = []
        shell.colorSchemeReportSink = { sent.append(String(decoding: $0, as: UTF8.self)) }

        shell.apply(theme: .light)
        #expect(sent.isEmpty, "nobody asked yet")

        shell.noteColorSchemeRequests(in: Array("\u{1b}[?2031h".utf8))
        shell.apply(theme: .dark)
        shell.apply(theme: .dark)
        shell.apply(theme: .light)
        #expect(sent == ["\u{1b}[?997;1n", "\u{1b}[?997;2n"], "once per change, not per apply")

        shell.noteColorSchemeRequests(in: Array("\u{1b}[?2031l".utf8))
        shell.apply(theme: .dark)
        #expect(sent.count == 2)
    }

    @Test("a query is answered with the scheme the pane has now")
    func answersQuery() {
        let shell = ShellTerminalView(spec: ShellSpec(theme: .light))
        var sent: [String] = []
        shell.colorSchemeReportSink = { sent.append(String(decoding: $0, as: UTF8.self)) }
        shell.noteColorSchemeRequests(in: Array("\u{1b}[?996n".utf8))
        #expect(sent == ["\u{1b}[?997;2n"])
    }
}
