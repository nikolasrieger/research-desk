import XCTest
@testable import ResearchDesk

final class WorkspaceLifetimeTests: XCTestCase {
    func testFileBrowserStateSurvivesProjectSwitch() async {
        await MainActor.run {
            let model = DeskModel(loadWorkspace: false)
            let first = Project(name: "First", path: "/tmp")
            let second = Project(name: "Second", path: "/tmp")
            let browser = model.fileBrowser(for: first)
            browser.search = "notes"
            browser.renderMarkdown = false
            _ = model.fileBrowser(for: second)
            XCTAssertTrue(model.fileBrowser(for: first) === browser)
            XCTAssertEqual(model.fileBrowser(for: first).search, "notes")
            XCTAssertFalse(model.fileBrowser(for: first).renderMarkdown)
            var moved = first
            moved.path = "/private/tmp"
            XCTAssertFalse(model.fileBrowser(for: moved) === browser)
        }
    }

    func testIndependentRunningSessionsAndTabs() async {
        await MainActor.run {
            let model = DeskModel(loadWorkspace: false)
            let first = Project(name: "First", path: "/tmp")
            let second = Project(name: "Second", path: "/tmp")
            let a = AgentSession(project: first, agent: "test", executable: "/bin/cat")
            let b = AgentSession(project: second, agent: "test", executable: "/bin/cat")
            model.sessions[first.id] = a
            model.sessions[second.id] = b
            defer { a.stop(); b.stop() }
            a.start()
            b.start()
            model.selected = first.id
            model.projectTabs[first.id] = 1
            model.selected = second.id
            model.projectTabs[second.id] = 0
            model.selected = first.id
            XCTAssertTrue(model.sessions[first.id] === a)
            XCTAssertTrue(model.sessions[second.id] === b)
            XCTAssertEqual(model.projectTabs[first.id], 1)
            XCTAssertTrue(a.terminal.process.running)
            XCTAssertTrue(b.terminal.process.running)
            XCTAssertNotEqual(a.terminal.process.shellPid, b.terminal.process.shellPid)
        }
    }
}
