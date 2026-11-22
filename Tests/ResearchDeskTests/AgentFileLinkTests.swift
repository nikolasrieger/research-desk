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
    func testSpacesParenthesesAndPercentEscapesInMarkdownLinks() throws {
        let project = Project(name: "Test", path: "/project")
        for (markdown, expected) in [
            ("[report](<docs/my report (final).md>)", "/project/docs/my report (final).md"),
            ("[plot](plots/plot(1).png)", "/project/plots/plot(1).png"),
            ("[report](docs/my%20report.md#results)", "/project/docs/my report.md"),
            ("[literal](docs/100%2520.txt)", "/project/docs/100%20.txt"),
            ("`/tmp/my report.md`", "/tmp/my report.md")
        ] {
            let linked = AgentFileLink.linkCodePaths(markdown)
            let attributed = try AttributedString(markdown: linked)
            let target = try XCTUnwrap(attributed.runs.compactMap { $0.link }.first, markdown)
            XCTAssertEqual(AgentFileLink.path(target, project: project), expected, markdown)
        }
    }
    func testClickedLocalFileOutsideProjectCanBeRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("my report (final).md")
        try Data("# Local preview".utf8).write(to: file)
        let workspace = Project(name: "Workspace", path: "/another/project")
        let path = try XCTUnwrap(AgentFileLink.path(file, project: workspace))
        let scoped = AgentFileLink.previewProject(path: path, project: workspace)
        let (data, failure) = Command.fileData(scoped, path: path)
        XCTAssertEqual(data, Data("# Local preview".utf8), failure)
        XCTAssertFalse(scoped.isRemote)
    }
    func testSSHAndNestedDocumentLinksKeepTheirConnection() throws {
        let project = Project(name: "Remote", path: "/home/user/project", host: "user@server")
        let url = try XCTUnwrap(URL(string: "ssh://user@server/home/user/report.md"))
        let path = try XCTUnwrap(AgentFileLink.path(url, project: project))
        let scoped = AgentFileLink.previewProject(path: path, project: project)
        XCTAssertEqual(scoped.host, "user@server")
        XCTAssertEqual(scoped.path, "/home/user")
        let relative = try XCTUnwrap(URL(string: "../images/plot.png"))
        let resolved = AgentFileLink.relativeLink(relative, document: "/home/user/project/docs/report.md", project: project)
        XCTAssertEqual(AgentFileLink.path(resolved, project: project), "/home/user/project/images/plot.png")
        XCTAssertNil(AgentFileLink.path(try XCTUnwrap(URL(string: "ssh://other/report.md")), project: project))
        let local = Project(name: "Local", path: "/tmp")
        XCTAssertEqual(AgentFileLink.path(try XCTUnwrap(URL(string: "~/report.md")), project: local), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("report.md").path)
    }

    func testRemoteTransferScriptWithFixtureAndSpaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/my report (final).md")
        try Data("SSH preview fixture".utf8).write(to: file)
        for path in [file.path, root.appendingPathComponent(file.lastPathComponent).path] {
            let project = Project(name: "Fixture", path: root.path)
            let resolved = try XCTUnwrap(AgentFileResolver.candidates(path: path, project: project).first)
            let (output, error, status) = Command.run("/usr/bin/python3", ["-c", FileBrowserIO.remoteCopyScript, root.path, resolved, "15000000"])
            XCTAssertEqual(status, 0, error)
            XCTAssertEqual(output, "SSH preview fixture")
        }
        let (_, error, status) = Command.run("/usr/bin/python3", ["-c", FileBrowserIO.remoteCopyScript, root.path, root.appendingPathComponent("missing.md").path, "15000000"])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(error.contains("Could not read"))
        XCTAssertFalse(error.contains("Traceback"))
    }

    func testBareFilenameResolvesNestedFilesAndOffersAmbiguousMatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["task-a", "task-b"] {
            let directory = root.appendingPathComponent("dataset/" + name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("[expected]".utf8).write(to: directory.appendingPathComponent("contract.toml"))
        }
        let project = Project(name: "Fixture", path: root.path)
        let matches = try AgentFileResolver.candidates(path: root.appendingPathComponent("contract.toml").path, project: project)
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        let exact = root.appendingPathComponent("dataset/task-a/contract.toml").path
        XCTAssertEqual(try AgentFileResolver.candidates(path: exact, project: project), [exact])
        XCTAssertEqual(try AgentFileResolver.candidates(path: root.appendingPathComponent("task-a/contract.toml").path, project: project), [exact])
        try FileManager.default.removeItem(atPath: matches.first { $0.contains("task-b") }!)
        XCTAssertEqual(try AgentFileResolver.candidates(path: root.appendingPathComponent("contract.toml").path, project: project), [exact])
    }

    func testExplicitPathsWorkForArbitraryOutputsOutsideWorkspace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let output = base.appendingPathComponent("unrelated/generated")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let project = Project(name: "Workspace", path: base.appendingPathComponent("workspace").path)
        for name in ["reward.json", "result.bin", "anything.xyz"] {
            let target = output.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: target)
            XCTAssertEqual(try AgentFileResolver.candidates(path: target.path, project: project), [target.path])
        }
        let link = try XCTUnwrap(URL(string: "research-file://open?path=src/main.py:12-20"))
        XCTAssertEqual(AgentFileLink.path(link, project: project), project.path + "/src/main.py")
    }
}
