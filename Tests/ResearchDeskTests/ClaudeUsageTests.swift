import XCTest
@testable import ResearchDesk

final class ClaudeUsageTests: XCTestCase {
    func testOldAndNewUsageFormats() throws {
        let old = try ClaudeUsageReading.parse(Data(#"{"five_hour":{"utilization":25,"resets_at":"2026-11-04T01:00:00Z"},"seven_day":{"utilization":43,"resets_at":"2026-11-07T01:00:00.126414+00:00"}}"#.utf8))
        XCTAssertEqual(old.session?.remaining, 75)
        XCTAssertEqual(old.weekly?.remaining, 57)
        XCTAssertNotNil(old.session?.resetsAt)
        XCTAssertNotNil(old.weekly?.resetsAt)
        let new = try ClaudeUsageReading.parse(Data(#"{"limits":[{"kind":"session","percent":120},{"kind":"weekly_all","percent":0}]}"#.utf8))
        XCTAssertEqual(new.session?.remaining, 0)
        XCTAssertEqual(new.weekly?.remaining, 100)
        let missing = try ClaudeUsageReading.parse(Data(#"{"seven_day":{"utilization":50}}"#.utf8))
        XCTAssertNil(missing.session)
        XCTAssertThrowsError(try ClaudeUsageReading.parse(Data("{}".utf8)))
    }
}
