import XCTest
@testable import ResearchDesk

final class AgentFileLinkTests: XCTestCase {
    func testResolveFileLinksAndLeaveWebLinksExternal() throws {
        let project = Project(name: "Test", path: "/project")
        XCTAssertEqual(AgentFileLink.path(try XCTUnwrap(URL(string: "docs/report.md#section")), project: project), "/project/docs/report.md")
        XCTAssertEqual(AgentFileLink.path(try XCTUnwrap(URL(string: "file:///project/code.py:12:3")), project: project), "/project/code.py")
        XCTAssertNil(AgentFileLink.path(try XCTUnwrap(URL(string: "https://example.com/report.html")), project: project))
        let linked = AgentFileLink.linkCodePaths("[report](docs/report.md#section)")
        let attributed = try AttributedString(markdown: linked)
        let target = try XCTUnwrap(attributed.runs.compactMap { $0.link }.first)
        XCTAssertEqual(AgentFileLink.path(target, project: project), "/project/docs/report.md")
        let source = AgentFileLink.linkCodePaths("See `outputs/plot.png` and `report.md:12`; keep `x = 1` plain.")
        XCTAssertTrue(source.contains("research-file://open?path=outputs/plot.png"))
        XCTAssertTrue(source.contains("[`report.md:12`]"))
        XCTAssertTrue(source.contains("`x = 1`"))
        XCTAssertTrue(AgentFileLink.linkCodePaths("[`report.md`](docs/report.md)").contains("research-file://open?path=docs/report.md"))
    }
}
