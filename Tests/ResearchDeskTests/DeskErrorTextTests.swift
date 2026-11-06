import XCTest
@testable import ResearchDesk

final class DeskErrorTextTests: XCTestCase {
    func testReadableSummaryAndFullTechnicalDetails() {
        let plain = DeskErrorText("You've hit your limit · resets at 3pm")
        XCTAssertFalse(plain.hasDetails)
        XCTAssertEqual(plain.summary, plain.details)
        let trace = DeskErrorText("\u{1B}[31mTraceback (most recent call last):\r\n  File xyz.py, line 7\nRuntimeError: not a git repository\u{1B}[0m")
        XCTAssertTrue(trace.hasDetails)
        XCTAssertEqual(trace.summary, "RuntimeError: not a git repository")
        XCTAssertFalse(trace.details.contains("\u{1B}"))
        XCTAssertTrue(trace.details.contains("File xyz.py"))
        let long = DeskErrorText(String(repeating: "error ", count: 100))
        XCTAssertLessThanOrEqual(long.summary.count, 241)
        XCTAssertEqual(long.details.count, 599)
    }
}
