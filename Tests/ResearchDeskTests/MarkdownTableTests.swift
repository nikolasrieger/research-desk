import XCTest
@testable import ResearchDesk

final class MarkdownTableTests: XCTestCase {
    func testPipeTablePreservesCellsAndInlinePipes() {
        let lines = ["| Name | Result |", "| :--- | ---: |", "| `a|b` | yes |", #"| escaped\|pipe | no |"#, "", "After table"]
        let table = MarkdownTableParser.parse(lines, at: 0)
        XCTAssertEqual(table?.consumed, 4)
        XCTAssertEqual(table?.rows, [["Name", "Result"], ["`a|b`", "yes"], ["escaped|pipe", "no"]])
    }
    func testTableCellsHaveBoundedWidthsAndPreserveExplicitLineBreaks() {
        XCTAssertEqual(MarkdownTableLayout.cellText("one<br>two<BR />three<br/>four"), "one\ntwo\nthree\nfour")
        let widths = MarkdownTableLayout.columnWidths([["Name", "Description"], ["A", String(repeating: "Long text ", count: 100)]])
        XCTAssertEqual(widths.count, 2)
        XCTAssertEqual(widths[1], 260)
        XCTAssertGreaterThanOrEqual(widths[0], 90)
        XCTAssertEqual(MarkdownTableLayout.columnWidths([]), [])
    }
    func testOrdinaryPipesAreNotTables() {
        XCTAssertNil(MarkdownTableParser.parse(["cat file | grep value", "Regular paragraph"], at: 0))
        XCTAssertNil(MarkdownTableParser.parse(["A | B", "--- | text"], at: 0))
    }
    func testTerminalTablesRetainMonospaceRows() {
        XCTAssertTrue(MarkdownTableParser.isTerminalBorder("┌────┬────┐"))
        XCTAssertTrue(MarkdownTableParser.isTerminalRow("│ A  │ B  │"))
        XCTAssertTrue(MarkdownTableParser.isTerminalRow("└────┴────┘"))
        XCTAssertTrue(MarkdownTableParser.isTerminalBorder("+-----+-----+"))
        XCTAssertFalse(MarkdownTableParser.isTerminalBorder("ordinary text"))
    }
}
