import Testing
import Foundation
@testable import UltraTiles

private let sample = """
diff --git a/Sources/App.swift b/Sources/App.swift
index 1a2b3c4..5d6e7f8 100644
--- a/Sources/App.swift
+++ b/Sources/App.swift
@@ -10,7 +10,8 @@ struct App {
     func start() {
         setUp()
-        let timeout = 30
+        let timeout = 45
         run(timeout: timeout)
+        tearDown()
     }
 }
"""

@Suite("Diff parsing")
struct DiffParserTests {

    @Test("hunk header gives both starting line numbers and the enclosing context")
    func hunkHeader() {
        let parsed = try! #require(DiffParser.parseHunkHeader("@@ -10,7 +10,8 @@ struct App {"))
        #expect(parsed.oldStart == 10)
        #expect(parsed.newStart == 10)
        #expect(parsed.heading == "struct App {")
    }

    @Test("a single-line hunk header has no comma and still parses")
    func singleLineHunk() {
        let parsed = try! #require(DiffParser.parseHunkHeader("@@ -3 +3 @@"))
        #expect(parsed.oldStart == 3)
        #expect(parsed.newStart == 3)
        #expect(parsed.heading.isEmpty)
    }

    @Test("the file header before the first @@ is not mistaken for content")
    func skipsFileHeader() {
        let diff = DiffParser.parse(sample, path: "Sources/App.swift", side: .unstaged)
        #expect(diff.hunks.count == 1)
        let texts = diff.hunks[0].lines.map(\.text)
        #expect(!texts.contains { $0.hasPrefix("diff --git") || $0.hasPrefix("a/Sources") })
    }

    @Test("additions and deletions are counted")
    func counts() {
        let diff = DiffParser.parse(sample, path: "Sources/App.swift", side: .unstaged)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        #expect(!diff.isEmpty)
    }

    /// Line numbers are the reason to render a diff rather than print it: they are what let
    /// someone jump to the change. They also desynchronise silently if the parser miscounts.
    @Test("line numbers track both sides independently")
    func lineNumbers() {
        let diff = DiffParser.parse(sample, path: "Sources/App.swift", side: .unstaged)
        let lines = diff.hunks[0].lines

        #expect(lines[0].oldNumber == 10 && lines[0].newNumber == 10)   // "func start() {"
        #expect(lines[1].oldNumber == 11 && lines[1].newNumber == 11)   // "setUp()"
        // A deletion advances only the old side; an addition only the new.
        #expect(lines[2].kind == .deletion && lines[2].oldNumber == 12 && lines[2].newNumber == nil)
        #expect(lines[3].kind == .addition && lines[3].newNumber == 12 && lines[3].oldNumber == nil)
        #expect(lines[4].oldNumber == 13 && lines[4].newNumber == 13)   // "run(timeout:...)"
        #expect(lines[5].kind == .addition && lines[5].newNumber == 14)
        #expect(lines[6].oldNumber == 14 && lines[6].newNumber == 15)   // "}"
    }

    /// A context line that is genuinely empty arrives as an EMPTY string, because git drops
    /// the single leading space. Treating it as a header desynchronises every number after it.
    @Test("an empty context line still advances both line numbers")
    func emptyContextLine() {
        let diff = DiffParser.parse("""
        @@ -1,4 +1,4 @@
         one

        -three
        +THREE
        """, path: "f.txt", side: .unstaged)
        let lines = diff.hunks[0].lines
        #expect(lines[1].kind == .context && lines[1].text.isEmpty)
        #expect(lines[2].oldNumber == 3, "the blank line must advance the count")
    }

    @Test("the no-newline marker is kept but is not content")
    func noNewlineMarker() {
        let diff = DiffParser.parse("""
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        """, path: "f.txt", side: .unstaged)
        let markers = diff.hunks[0].lines.filter { $0.kind == .marker }
        #expect(markers.count == 1)
        #expect(diff.additions == 1 && diff.deletions == 1)
    }

    @Test("a binary file reports itself rather than rendering as text")
    func binary() {
        let diff = DiffParser.parse("""
        diff --git a/logo.png b/logo.png
        index 1a2b3c4..5d6e7f8 100644
        Binary files a/logo.png and b/logo.png differ
        """, path: "logo.png", side: .unstaged)
        #expect(diff.isBinary)
        #expect(!diff.isEmpty, "binary is not the same as no change")
    }

    @Test("no output means no change")
    func emptyDiff() {
        let diff = DiffParser.parse("", path: "f.swift", side: .staged)
        #expect(diff.isEmpty)
        #expect(diff.side == .staged)
    }

    @Test("multiple hunks are kept separate with their own headings")
    func multipleHunks() {
        let diff = DiffParser.parse("""
        @@ -1,3 +1,3 @@ first
        -a
        +A
        @@ -20,3 +20,3 @@ second
        -b
        +B
        """, path: "f.swift", side: .unstaged)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].heading == "first")
        #expect(diff.hunks[1].heading == "second")
        #expect(diff.hunks[1].oldStart == 20)
    }
}

@Suite("Intra-line highlighting")
struct DiffEmphasisTests {

    /// The whole point: a one-character change in a long line is invisible when the entire
    /// line is coloured.
    @Test("only the changed span is marked")
    func marksTheChange() {
        let region = try! #require(DiffParser.changedRegion("let timeout = 30",
                                                            "let timeout = 45"))
        #expect(region.0 == 14..<16)
        #expect(region.1 == 14..<16)
    }

    @Test("an insertion in the middle marks an empty span on the old side")
    func insertion() {
        let region = try! #require(DiffParser.changedRegion("run(x)", "run(x, y)"))
        #expect(region.0.isEmpty)
        #expect(!region.1.isEmpty)
    }

    /// Highlighting the whole of both lines says nothing the colour did not already say.
    @Test("two unrelated lines get no highlight at all")
    func unrelatedLinesAreNotMarked() {
        #expect(DiffParser.changedRegion("import Foundation",
                                         "let x = compute(a, b, c)") == nil)
    }

    @Test("identical lines have nothing to mark")
    func identical() {
        #expect(DiffParser.changedRegion("same", "same") == nil)
    }

    @Test("a modified pair inside a hunk carries the emphasis through")
    func emphasisReachesTheLines() {
        let diff = DiffParser.parse(sample, path: "Sources/App.swift", side: .unstaged)
        let deletion = try! #require(diff.hunks[0].lines.first { $0.kind == .deletion })
        let addition = try! #require(diff.hunks[0].lines.first { $0.kind == .addition })
        // Offsets are into the line's own text, indentation included: the sample's lines
        // carry eight leading spaces, so "30" -> "45" sits at 22, not 14.
        #expect(deletion.emphasis == [22..<24])
        #expect(addition.emphasis == [22..<24])
    }

    /// Pairing by position across runs of different length highlights unrelated text, so
    /// unequal runs are left alone.
    @Test("unequal runs of deletions and additions are not paired")
    func unequalRunsAreNotPaired() {
        let diff = DiffParser.parse("""
        @@ -1,3 +1,4 @@
        -one
        +ONE
        +two
        +three
        """, path: "f.txt", side: .unstaged)
        #expect(diff.hunks[0].lines.allSatisfy { $0.emphasis.isEmpty })
    }
}
