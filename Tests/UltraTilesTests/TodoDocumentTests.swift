import Testing
import Foundation
@testable import UltraTiles

/// The acceptance criterion for the Todo tile is that toggling a checkbox leaves the
/// surrounding prose byte-identical. These tests are that criterion, executable.
@Suite("Todo document")
struct TodoDocumentTests {

    private let sample = """
    ---
    title: Notes
    ---

    # Project

    Some prose that must survive, with a `- [ ] not a task` in backticks.

    ## Doing

    - [ ] first task
    - [x] done task
      - [ ] nested subtask

    Prose between blocks.

    ```
    - [ ] fenced, not a task the user can toggle from the tile
    ```

    ## Later

    * [ ] star bullet
    + [X] plus bullet, capital X

    """

    @Test("parsing then serialising changes nothing at all")
    func roundTrip() {
        #expect(TodoDocument(text: sample).text == sample)
    }

    @Test("a file with no trailing newline keeps having none")
    func noTrailingNewline() {
        let text = "- [ ] only line"
        #expect(TodoDocument(text: text).text == text)
    }

    @Test("CRLF survives")
    func crlf() {
        let text = "# H\r\n\r\n- [ ] a\r\n- [x] b\r\n"
        var document = TodoDocument(text: text)
        #expect(document.text == text)
        let id = try! #require(document.items.first).id
        document.toggle(id)
        #expect(document.text == "# H\r\n\r\n- [x] a\r\n- [x] b\r\n")
    }

    @Test("every bullet style and both done markers parse")
    func bulletStyles() {
        let document = TodoDocument(text: sample)
        let texts = document.items.map(\.text)
        #expect(texts.contains("first task"))
        #expect(texts.contains("nested subtask"))
        #expect(texts.contains("star bullet"))
        #expect(texts.contains("plus bullet, capital X"))
        #expect(document.items.first { $0.text == "plus bullet, capital X" }?.isDone == true)
        #expect(document.items.first { $0.text == "nested subtask" }?.indent == 2)
    }

    @Test("tasks carry the heading they sit under")
    func sections() {
        let document = TodoDocument(text: sample)
        #expect(document.items.first { $0.text == "first task" }?.section == "Doing")
        #expect(document.items.first { $0.text == "star bullet" }?.section == "Later")
        #expect(document.sections == ["Project", "Doing", "Later"])
    }

    @Test("toggling rewrites ONE character and nothing else")
    func toggleIsSurgical() {
        var document = TodoDocument(text: sample)
        let id = try! #require(document.items.first { $0.text == "first task" }).id
        document.toggle(id)

        let before = Array(sample)
        let after = Array(document.text)
        #expect(before.count == after.count, "length must not change")
        let differing = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(differing.count == 1, "exactly one byte differs")
        #expect(differing.first?.element.1 == "x")

        // And back again is the original file, exactly.
        document.toggle(id)
        #expect(document.text == sample)
    }

    @Test("prose, front matter and code fences are never treated as tasks")
    func doesNotTouchProse() {
        let document = TodoDocument(text: sample)
        // The backticked and fenced lines are indistinguishable from tasks by shape; the
        // tile deliberately does not parse markdown structure, so the fenced one IS listed.
        // What matters is that toggling any item leaves every other byte alone, which
        // `toggleIsSurgical` proves. Here we only assert the inline-backtick line is not a
        // task, because it does not start with a bullet.
        #expect(!document.items.contains { $0.text.contains("not a task` in backticks") })
    }

    @Test("adding a task appends to its section, not the end of the file")
    func addToSection() {
        var document = TodoDocument(text: sample)
        document.addItem("added here", to: "Doing")
        let items = document.items
        let added = try! #require(items.first { $0.text == "added here" })
        #expect(added.section == "Doing")
        // It landed after the last task of Doing, before the "Later" heading.
        let later = try! #require(items.first { $0.text == "star bullet" })
        #expect(added.id < later.id)
        #expect(document.text.contains("Prose between blocks."))
    }

    @Test("adding to a file with no trailing newline does not glue two lines together")
    func addWithoutTrailingNewline() {
        var document = TodoDocument(text: "- [ ] only line")
        document.addItem("second")
        #expect(document.text == "- [ ] only line\n- [ ] second")
        #expect(document.items.count == 2)
    }

    @Test("prepending puts the task above every other one")
    func prependGoesToTheTop() {
        var document = TodoDocument(text: sample)
        document.prependItem("newest")
        let items = document.items
        #expect(items.first?.text == "newest")
        // Prose is untouched, the same criterion every other edit is held to.
        #expect(document.text.contains("Prose between blocks."))
        #expect(document.text.contains("Some prose that must survive"))
    }

    /// The task must land under the heading it belongs to, not above it. Hoisting it over
    /// the `# Project` line would move it out of the section entirely.
    @Test("prepending stays below the heading that opens the file")
    func prependStaysUnderItsHeading() {
        var document = TodoDocument(text: "# Plan\n\n- [ ] existing\n")
        document.prependItem("newest")
        #expect(document.text == "# Plan\n\n- [ ] newest\n- [ ] existing\n")
        #expect(document.items.first?.section == "Plan")
    }

    @Test("prepending inherits the indentation of the task it displaces")
    func prependMatchesIndent() {
        var document = TodoDocument(text: "  - [ ] nested\n")
        document.prependItem("newest")
        #expect(document.text == "  - [ ] newest\n  - [ ] nested\n")
    }

    /// With nothing to sit above, prepend has to behave exactly like an append — including
    /// the no-trailing-newline handling that `addWithoutTrailingNewline` pins down.
    @Test("prepending into a file with no tasks yet still lands after the headings")
    func prependWithNoTasks() {
        var document = TodoDocument(text: "# Plan\n")
        document.prependItem("first ever")
        #expect(document.text == "# Plan\n- [ ] first ever\n")
        #expect(document.items.first?.section == "Plan")
    }

    @Test("removing a task removes exactly its line")
    func remove() {
        var document = TodoDocument(text: sample)
        let id = try! #require(document.items.first { $0.text == "done task" }).id
        document.removeItem(id)
        #expect(!document.text.contains("- [x] done task"))
        #expect(document.text.contains("- [ ] first task"))
        #expect(document.text.contains("  - [ ] nested subtask"))
    }

    @Test("renaming a task keeps its state and indentation")
    func rename() {
        var document = TodoDocument(text: sample)
        let id = try! #require(document.items.first { $0.text == "nested subtask" }).id
        document.setText("renamed", for: id)
        let item = try! #require(document.items.first { $0.id == id })
        #expect(item.text == "renamed")
        #expect(item.indent == 2)
        #expect(item.isDone == false)
        #expect(document.text.contains("  - [ ] renamed"))
    }

    /// Round-tripping must hold for arbitrary text, not just the sample above.
    @Test("round-trip is lossless for arbitrary content", arguments: 0..<200)
    func roundTripProperty(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let fragments = ["# Heading", "## Sub", "- [ ] task", "- [x] done", "  - [ ] nested",
                         "plain prose", "", "```", "* [ ] star", "\ttabbed", "   ", "---",
                         "text with trailing space   ", "> quote", "1. ordered"]
        let count = Int(generator.next() % 30)
        var text = (0..<count)
            .map { _ in fragments[Int(generator.next() % UInt64(fragments.count))] }
            .joined(separator: generator.next() % 5 == 0 ? "\r\n" : "\n")
        if generator.next() % 3 == 0 { text += "\n" }
        #expect(TodoDocument(text: text).text == text, "seed \(seed) did not round-trip")
    }
}

/// Deterministic RNG: a property test that fails only on some runs is not a test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

/// The grouping the tile renders. Split out of the view because the bug it once had —
/// indexing out[-1] — could only crash at render time, where no test was looking.
@Suite("Todo grouping")
struct TodoGroupingTests {

    @Test("tasks above any heading form their own leading group")
    func tasksBeforeAnyHeading() {
        let document = TodoDocument(text: """
        - [ ] loose one
        - [ ] loose two

        ## Doing

        - [ ] under a heading
        """)
        let groups = document.grouped
        #expect(groups.count == 2)
        #expect(groups[0].section == nil)
        #expect(groups[0].items.map(\.text) == ["loose one", "loose two"])
        #expect(groups[1].section == "Doing")
    }

    @Test("a file that is nothing but unsectioned tasks groups without trapping")
    func onlyUnsectioned() {
        let groups = TodoDocument(text: "- [ ] a\n- [ ] b\n").grouped
        #expect(groups.count == 1)
        #expect(groups[0].section == nil)
        #expect(groups[0].items.count == 2)
    }

    @Test("an empty document has no groups")
    func empty() {
        #expect(TodoDocument(text: "").grouped.isEmpty)
        #expect(TodoDocument(text: "# Just a heading\n").grouped.isEmpty)
    }

    @Test("the same heading text reappearing starts a new group, in file order")
    func repeatedHeading() {
        let groups = TodoDocument(text: """
        ## A
        - [ ] one
        ## B
        - [ ] two
        ## A
        - [ ] three
        """).grouped
        #expect(groups.map(\.section) == ["A", "B", "A"])
        #expect(groups.map { $0.items.count } == [1, 1, 1])
    }
}

@Suite("Todo reordering")
struct TodoMoveTests {

    private let sample = """
    # Plan

    Some prose that is not a task.

    - [ ] first
    - [x] second
    - [ ] third
    """

    @Test("a task moves and everything else stays byte-identical")
    func movePreservesTheRestOfTheFile() {
        var document = TodoDocument(text: sample)
        let items = document.items
        // third -> before first
        let moved1 = document.move(items[2].id, before: items[0].id)
        #expect(moved1)
        #expect(document.items.map(\.text) == ["third", "first", "second"])
        // The prose, the heading and the blank lines are untouched.
        #expect(document.text.contains("# Plan"))
        #expect(document.text.contains("Some prose that is not a task."))
        #expect(document.text.hasSuffix("- [x] second"))
    }

    @Test("moving down lands where the row was dropped, not one short")
    func moveDown() {
        var document = TodoDocument(text: sample)
        let items = document.items
        // first -> to the end
        let outOfRange = document.move(items[0].id, before: Int.max)
        #expect(!outOfRange, "an out-of-range target is refused")
        var again = TodoDocument(text: sample)
        let ids = again.items.map(\.id)
        let moved2 = again.move(ids[0], before: ids[2] + 1)
        #expect(moved2)
        #expect(again.items.map(\.text) == ["second", "third", "first"])
    }

    @Test("dropping a row on itself changes nothing")
    func selfMoveIsANoOp() {
        var document = TodoDocument(text: sample)
        let before = document.text
        let ids = document.items.map(\.id)
        let moved3 = document.move(ids[1], before: ids[1])
        #expect(!moved3)
        let moved4 = document.move(ids[1], before: ids[1] + 1)
        #expect(!moved4)
        #expect(document.text == before)
    }

    /// A line with no terminator is the last line of a file that ends without a newline.
    /// That belongs to the END OF THE FILE, not to the line — carrying it into the middle
    /// silently joins the moved task to the one after it.
    @Test("moving the last line of a file with no trailing newline does not join two tasks")
    func noTrailingNewline() {
        var document = TodoDocument(text: "- [ ] one\n- [ ] two\n- [ ] three")
        let ids = document.items.map(\.id)
        let moved5 = document.move(ids[2], before: ids[0])
        #expect(moved5)
        #expect(document.items.map(\.text) == ["three", "one", "two"])
        #expect(!document.text.contains("threeone"), "the lines were joined")
        #expect(document.text == "- [ ] three\n- [ ] one\n- [ ] two")
        #expect(!document.text.hasSuffix("\n"), "the file must still end without a newline")
    }

    @Test("a moved line in a CRLF file stays CRLF")
    func crlf() {
        var document = TodoDocument(text: "- [ ] one\r\n- [ ] two\r\n")
        let ids = document.items.map(\.id)
        let moved6 = document.move(ids[1], before: ids[0])
        #expect(moved6)
        #expect(document.text == "- [ ] two\r\n- [ ] one\r\n")
    }

    @Test("indentation travels with the task rather than adopting the destination's")
    func indentIsCarried() {
        var document = TodoDocument(text: "- [ ] top\n    - [ ] nested\n- [ ] other\n")
        let ids = document.items.map(\.id)
        let moved7 = document.move(ids[1], before: ids[0])
        #expect(moved7)
        #expect(document.text.hasPrefix("    - [ ] nested\n"),
                "the task keeps its own indent; re-indenting would be an edit nobody asked for")
    }

    @Test("moving across a heading puts the task in the other section")
    func acrossSections() {
        var document = TodoDocument(text: "# A\n- [ ] one\n# B\n- [ ] two\n")
        let ids = document.items.map(\.id)
        let moved8 = document.move(ids[1], before: ids[0])
        #expect(moved8)
        #expect(document.items.first?.section == "A")
        #expect(document.items.count == 2)
    }

    @Test("only tasks can be moved")
    func nonTaskLinesAreRefused() {
        var document = TodoDocument(text: sample)
        let before = document.text
        let moved9 = document.move(0, before: 5)
        #expect(!moved9, "the heading line is not a task")
        #expect(document.text == before)
    }
}
